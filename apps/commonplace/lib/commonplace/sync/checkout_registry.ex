defmodule Commonplace.Sync.CheckoutRegistry do
  @moduledoc """
  Central coordinator for the multi-checkout system.

  Persists checkout definitions (sync_dir → uuid mappings) in a JSON file
  and manages the lifecycle of DirAgent/EntryAgent processes for each checkout.

  On init, reads the JSON file and spawns agents for each persisted checkout.
  All mutations (register, unregister, reroot) are persisted atomically.
  """

  use GenServer

  alias Commonplace.Sync.{DirAgent, EntryAgent}

  defstruct [
    :config_path,
    :store,
    checkouts: []
  ]

  # Each checkout entry in the list
  defmodule Checkout do
    @moduledoc false
    defstruct [:sync_dir, :uuid, :type, :pid]
  end

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Register a new checkout. Spawns the appropriate agent and persists."
  def register(pid, sync_dir, uuid, type) when type in [:dir, :file] do
    GenServer.call(pid, {:register, sync_dir, uuid, type})
  end

  @doc "Unregister a checkout. Stops the agent, removes from persistence."
  def unregister(pid, sync_dir) do
    GenServer.call(pid, {:unregister, sync_dir})
  end

  @doc "Reroot a checkout to a different uuid. Stops old agent, spawns new one."
  def reroot(pid, sync_dir, new_uuid) do
    GenServer.call(pid, {:reroot, sync_dir, new_uuid})
  end

  @doc "List all active checkouts."
  def list(pid) do
    GenServer.call(pid, :list)
  end

  @doc """
  Find the checkout whose `sync_dir` most tightly encloses `cwd`
  (CX-voi).

  Reads the persisted `checkouts.json` directly — no running
  registry process required. Used by the MCP presence bootstrap to
  place the agent's .bot file in the sandbox checkout it was launched
  from, rather than always at the workspace root.

  Returns `{:ok, %{uuid, sync_dir, type}}` for the longest matching
  prefix, or `:none` when the config is missing / cwd is outside
  every checkout. "Inside" means `cwd == sync_dir` or `cwd` lives at
  or below `sync_dir/` — a sync_dir that's merely a string prefix of
  cwd (e.g. `/ws/repo` vs `/ws/repo-backup`) is NOT a match.
  """
  @spec find_for_cwd(String.t(), String.t()) ::
          {:ok, %{uuid: String.t(), sync_dir: String.t(), type: atom()}} | :none
  def find_for_cwd(config_path, cwd) when is_binary(config_path) and is_binary(cwd) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, entries} when is_list(entries) <- Jason.decode(contents) do
      entries
      |> Enum.filter(&cwd_in_checkout?(cwd, &1["sync_dir"]))
      |> Enum.max_by(fn entry -> String.length(entry["sync_dir"] || "") end, fn -> nil end)
      |> case do
        nil -> :none
        entry -> {:ok, entry_to_map(entry)}
      end
    else
      _ -> :none
    end
  end

  defp cwd_in_checkout?(_cwd, nil), do: false

  defp cwd_in_checkout?(cwd, sync_dir) do
    cwd == sync_dir or String.starts_with?(cwd, sync_dir <> "/")
  end

  defp entry_to_map(entry) do
    %{
      uuid: entry["uuid"],
      sync_dir: entry["sync_dir"],
      type: parse_type(entry["type"])
    }
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    store = Keyword.fetch!(opts, :store)

    state = %__MODULE__{
      config_path: config_path,
      store: store,
      checkouts: []
    }

    state = load_and_spawn(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:register, sync_dir, uuid, type}, _from, state) do
    if find_checkout(state, sync_dir) do
      {:reply, {:error, :already_registered}, state}
    else
      case spawn_agent(type, sync_dir, uuid, state.store) do
        {:ok, pid} ->
          checkout = %Checkout{sync_dir: sync_dir, uuid: uuid, type: type, pid: pid}
          state = %{state | checkouts: state.checkouts ++ [checkout]}
          persist(state)
          write_breadcrumb(sync_dir, type, state.config_path)

          {:reply, {:ok, checkout_to_map(checkout)}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:unregister, sync_dir}, _from, state) do
    case find_checkout(state, sync_dir) do
      nil ->
        {:reply, {:error, :not_found}, state}

      checkout ->
        stop_agent(checkout.pid)
        remove_breadcrumb(sync_dir, checkout.type)
        state = %{state | checkouts: reject_checkout(state, sync_dir)}
        persist(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:reroot, sync_dir, new_uuid}, _from, state) do
    case find_checkout(state, sync_dir) do
      nil ->
        {:reply, {:error, :not_found}, state}

      checkout ->
        # Stop old agent
        stop_agent(checkout.pid)

        # Spawn new agent with updated uuid
        case spawn_agent(checkout.type, sync_dir, new_uuid, state.store) do
          {:ok, new_pid} ->
            new_checkout = %Checkout{
              sync_dir: sync_dir,
              uuid: new_uuid,
              type: checkout.type,
              pid: new_pid
            }

            state = %{state | checkouts: replace_checkout(state, sync_dir, new_checkout)}
            persist(state)

            # Log reroot event on red channel
            reroot_event = %{
              "type" => "reroot",
              "from_root" => checkout.uuid,
              "to_root" => new_uuid,
              "checkout_path" => sync_dir,
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            Commonplace.Dataflow.PubSub.broadcast_red(
              "checkout:reroot",
              Jason.encode!(reroot_event)
            )

            {:reply, {:ok, checkout_to_map(new_checkout)}, state}

          {:error, reason} ->
            # Remove the checkout since old agent was stopped
            state = %{state | checkouts: reject_checkout(state, sync_dir)}
            persist(state)
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:list, _from, state) do
    list = Enum.map(state.checkouts, &checkout_to_map/1)
    {:reply, list, state}
  end

  # --- Persistence ---

  defp load_and_spawn(state) do
    case File.read(state.config_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, entries} when is_list(entries) ->
            checkouts =
              entries
              |> Enum.map(fn entry ->
                type = parse_type(entry["type"])
                sync_dir = entry["sync_dir"]
                uuid = entry["uuid"]

                case spawn_agent(type, sync_dir, uuid, state.store) do
                  {:ok, pid} ->
                    %Checkout{sync_dir: sync_dir, uuid: uuid, type: type, pid: pid}

                  {:error, reason} ->
                    require Logger
                    Logger.warning("CheckoutRegistry: failed to spawn agent for #{sync_dir} (#{uuid}): #{inspect(reason)}")
                    nil
                end
              end)
              |> Enum.reject(&is_nil/1)

            %{state | checkouts: checkouts}

          _ ->
            state
        end

      {:error, _} ->
        state
    end
  end

  defp persist(state) do
    entries =
      Enum.map(state.checkouts, fn checkout ->
        %{
          "sync_dir" => checkout.sync_dir,
          "uuid" => checkout.uuid,
          "type" => Atom.to_string(checkout.type)
        }
      end)

    json = Jason.encode!(entries, pretty: true)
    atomic_write(state.config_path, json)
  end

  defp atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.tmp.#{System.pid()}")

    try do
      File.write!(tmp_path, content)

      case :file.open(String.to_charlist(tmp_path), [:read]) do
        {:ok, fd} ->
          :file.datasync(fd)
          :file.close(fd)

        {:error, _} ->
          :ok
      end

      File.rename!(tmp_path, path)
    rescue
      error ->
        File.rm(tmp_path)
        reraise error, __STACKTRACE__
    end
  end

  defp parse_type("dir"), do: :dir
  defp parse_type("file"), do: :file

  # --- Agent lifecycle ---

  defp spawn_agent(:dir, sync_dir, uuid, store) do
    DynamicSupervisor.start_child(
      Commonplace.Checkout.Supervisor,
      {DirAgent,
       schema_uuid: uuid,
       dir_path: sync_dir,
       store: store}
    )
  end

  defp spawn_agent(:file, sync_dir, uuid, store) do
    DynamicSupervisor.start_child(
      Commonplace.Checkout.Supervisor,
      {EntryAgent,
       doc_uuid: uuid,
       file_path: sync_dir,
       store: store,
       standalone: true}
    )
  end

  defp stop_agent(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        DynamicSupervisor.terminate_child(Commonplace.Checkout.Supervisor, pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp stop_agent(_), do: :ok

  # --- Breadcrumb management ---

  defp write_breadcrumb(sync_dir, type, config_path) do
    db_dir = Path.dirname(config_path)

    # Don't write breadcrumbs for checkouts inside the .commonplace tree
    if not String.starts_with?(sync_dir, db_dir) do
      breadcrumb_dir =
        case type do
          :dir -> sync_dir
          :file -> Path.dirname(sync_dir)
        end

      ref_path = Path.join(breadcrumb_dir, ".commonplace-ref")
      File.mkdir_p!(breadcrumb_dir)
      File.write!(ref_path, db_dir)
    end
  end

  defp remove_breadcrumb(sync_dir, type) do
    breadcrumb_dir =
      case type do
        :dir -> sync_dir
        :file -> Path.dirname(sync_dir)
      end

    ref_path = Path.join(breadcrumb_dir, ".commonplace-ref")
    File.rm(ref_path)
  end

  # --- Checkout list helpers ---

  defp find_checkout(state, sync_dir) do
    Enum.find(state.checkouts, &(&1.sync_dir == sync_dir))
  end

  defp reject_checkout(state, sync_dir) do
    Enum.reject(state.checkouts, &(&1.sync_dir == sync_dir))
  end

  defp replace_checkout(state, sync_dir, new_checkout) do
    Enum.map(state.checkouts, fn c ->
      if c.sync_dir == sync_dir, do: new_checkout, else: c
    end)
  end

  defp checkout_to_map(%Checkout{} = c) do
    %{sync_dir: c.sync_dir, uuid: c.uuid, type: c.type, pid: c.pid}
  end
end
