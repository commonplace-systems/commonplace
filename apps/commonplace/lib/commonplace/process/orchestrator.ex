defmodule Commonplace.Process.Orchestrator do
  @moduledoc """
  Watches __processes.json and manages Elixir process lifecycle.

  Periodically reads the __processes.json CRDT doc, diffs against
  the current running state, and starts/stops/restarts processes
  to match the declared configuration.

  Each Elixir process is compiled from a source .exs document in
  the CRDT tree and started as a supervised GenServer.
  """

  use GenServer

  alias Commonplace.Process.Config
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType

  defstruct [:root_uuid, :store, :interval, :processes, :current_config, :source_hashes]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Get the map of running process names to pids."
  def running_processes(pid) do
    GenServer.call(pid, :running_processes)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      root_uuid: Keyword.fetch!(opts, :root_uuid),
      store: Keyword.get(opts, :store, CommitStore),
      interval: Keyword.get(opts, :interval, 5000),
      processes: %{},
      current_config: [],
      source_hashes: %{}
    }

    schedule_reconcile(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:running_processes, _from, state) do
    {:reply, state.processes, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state =
      try do
        reconcile(state)
      rescue
        _ -> state
      end

    schedule_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.processes, fn {_name, pid} ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, 1000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp reconcile(state) do
    new_config = read_processes_config(state)
    diff = Config.diff(state.current_config, new_config)

    source_changes = detect_source_changes(state, new_config)
    all_changed = Enum.uniq(diff.changed ++ source_changes)

    state = stop_processes(state, diff.removed ++ all_changed)
    state = start_processes(state, diff.added ++ all_changed, new_config)

    %{state | current_config: new_config}
  end

  defp stop_processes(state, names) do
    Enum.reduce(names, state, fn name, acc ->
      case Map.get(acc.processes, name) do
        nil ->
          acc

        pid ->
          if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, 5000)
          %{acc | processes: Map.delete(acc.processes, name)}
      end
    end)
  end

  defp start_processes(state, names, config_list) do
    config_map = Map.new(config_list, &{&1.name, &1})

    Enum.reduce(names, state, fn name, acc ->
      case Map.get(config_map, name) do
        nil ->
          acc

        config ->
          case start_process(config, acc) do
            {:ok, pid, source_hash} ->
              %{acc |
                processes: Map.put(acc.processes, name, pid),
                source_hashes: Map.put(acc.source_hashes, name, source_hash)
              }

            {:error, _reason} ->
              acc
          end
      end
    end)
  end

  defp start_process(%Config{mode: :elixir} = config, state) do
    case read_source(config.source, state) do
      {:ok, source_code, source_hash} ->
        try do
          Code.compile_string(source_code)

          module_name = module_for(config.name)

          init_opts = [
            store: state.store,
            root_uuid: state.root_uuid,
            name: config.name,
            config: %{
              "source" => config.source,
              "owns" => config.owns,
              "restart" => Atom.to_string(config.restart),
              "depends_on" => config.depends_on
            }
          ]

          # Use start (not start_link) to avoid linking child to orchestrator
          case GenServer.start(module_name, init_opts) do
            {:ok, pid} -> {:ok, pid, source_hash}
            error -> {:error, error}
          end
        rescue
          e -> {:error, e}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp detect_source_changes(state, new_config) do
    Enum.flat_map(new_config, fn config ->
      if Map.has_key?(state.processes, config.name) do
        case read_source(config.source, state) do
          {:ok, _code, hash} ->
            old_hash = Map.get(state.source_hashes, config.name)
            if old_hash != nil and old_hash != hash, do: [config.name], else: []

          _ ->
            []
        end
      else
        []
      end
    end)
  end

  defp read_source(filename, state) do
    root_doc = load_schema(state.root_uuid, state.store)

    case Schema.get_entry(root_doc, filename) do
      {:ok, entry} ->
        case CommitStore.latest_commit(state.store, entry.node_id) do
          {:ok, commit} ->
            doc = Yelixer.Doc.new()
            {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
            content = ContentType.get_content(doc) || ""
            hash = :erlang.md5(content)
            {:ok, content, hash}

          :none ->
            {:error, :no_commit}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp read_processes_config(state) do
    root_doc = load_schema(state.root_uuid, state.store)

    case Schema.get_entry(root_doc, "__processes.json") do
      {:ok, entry} ->
        case CommitStore.latest_commit(state.store, entry.node_id) do
          {:ok, commit} ->
            doc = Yelixer.Doc.new()
            {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
            content = ContentType.get_content(doc) || "{}"

            case Jason.decode(content) do
              {:ok, json} -> Config.parse(json)
              {:error, _} -> []
            end

          :none ->
            []
        end

      :error ->
        []
    end
  end

  defp module_for(name) do
    camel = name |> Macro.camelize()
    Module.concat([Commonplace.UserProcess, camel])
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp schedule_reconcile(state) do
    Process.send_after(self(), :reconcile, state.interval)
  end
end
