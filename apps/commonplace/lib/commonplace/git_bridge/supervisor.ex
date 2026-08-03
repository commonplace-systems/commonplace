defmodule Commonplace.GitBridge.Supervisor do
  @moduledoc """
  Supervises one `Commonplace.GitBridge.Server` per durable mount ->
  repo_dir mapping.

  Mappings are node-local plain data — a JSON file at
  `<data_dir>/git_bridges.json` (NOT a synced CRDT doc; each node's set
  of git mirrors is its own operational config, akin to CommitStore's
  data_dir itself). `data_dir` defaults to
  `Application.get_env(:commonplace, :git_bridge_data_dir)` so
  production wiring is a one-line config, but every argument is
  overridable so tests can point it at a tmp dir.

  Wired into `Commonplace.Application`'s tree via
  `git_bridge_children/0` (default-on outside test): the durable-mapping
  requirement is that bridges RESTART ON NODE BOOT from the persisted
  file — a mirror that silently stays down after a reboot looks covered
  while backing up nothing. "Which mounts get mirrored" IS the mapping
  file (absent/empty ⇒ zero children); remote credentials come from
  SecretStore at push time. Tests start isolated instances via
  `start_supervised!({Commonplace.GitBridge.Supervisor, opts})`.
  """

  use Supervisor
  require Logger

  alias Commonplace.GitBridge.{CanonicalJson, Server}

  @mapping_file "git_bridges.json"

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    data_dir = data_dir(opts)
    store = Keyword.fetch!(opts, :store)
    File.mkdir_p!(data_dir)

    mappings = read_mappings(data_dir)

    children =
      Enum.map(mappings, fn mapping ->
        Supervisor.child_spec(
          {Server, server_opts(mapping, store)},
          id: child_id(mapping)
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Add a new mapping: persists it to `git_bridges.json` and starts a
  `Server` child for it.

  Rejects (`{:error, reason}`, no file write, no child started) when:
    * `repo_dir` matches an existing mapping's `repo_dir`;
    * `remote` is non-nil and matches an existing mapping's non-nil
      `remote`.
  """
  @spec add_mapping(Supervisor.supervisor(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_mapping(supervisor, mapping, opts \\ []) do
    data_dir = data_dir(opts)
    store = Keyword.fetch!(opts, :store)
    mapping = normalize_mapping(mapping)
    mappings = read_mappings(data_dir)

    cond do
      Enum.any?(mappings, &(&1["repo_dir"] == mapping["repo_dir"])) ->
        {:error, :repo_dir_already_mapped}

      not is_nil(mapping["remote"]) and
          Enum.any?(mappings, &(&1["remote"] == mapping["remote"])) ->
        {:error, :remote_already_mapped}

      true ->
        new_mappings = mappings ++ [mapping]
        write_mappings(data_dir, new_mappings)

        case Supervisor.start_child(
               supervisor,
               Supervisor.child_spec({Server, server_opts(mapping, store)}, id: child_id(mapping))
             ) do
          {:ok, _pid} -> {:ok, mapping}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Remove a mapping by `mount_uuid` or `repo_dir`: deletes it from
  `git_bridges.json` and stops/terminates its `Server` child.
  """
  @spec remove_mapping(Supervisor.supervisor(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_mapping(supervisor, mount_uuid_or_repo_dir, opts \\ []) do
    data_dir = data_dir(opts)
    mappings = read_mappings(data_dir)

    case Enum.find(mappings, &matches?(&1, mount_uuid_or_repo_dir)) do
      nil ->
        {:error, :not_found}

      mapping ->
        new_mappings = Enum.reject(mappings, &matches?(&1, mount_uuid_or_repo_dir))
        write_mappings(data_dir, new_mappings)

        id = child_id(mapping)
        _ = Supervisor.terminate_child(supervisor, id)
        _ = Supervisor.delete_child(supervisor, id)
        :ok
    end
  end

  # --- Private ---

  defp matches?(mapping, key), do: mapping["mount_uuid"] == key or mapping["repo_dir"] == key

  defp data_dir(opts) do
    Keyword.get_lazy(opts, :data_dir, fn ->
      Application.get_env(:commonplace, :git_bridge_data_dir, "data/git_bridges")
    end)
  end

  defp mapping_path(data_dir), do: Path.join(data_dir, @mapping_file)

  defp read_mappings(data_dir) do
    path = mapping_path(data_dir)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, list} when is_list(list) ->
            list

          error ->
            Logger.error(
              "GitBridge.Supervisor: failed to decode #{path} (#{inspect(error)}) — " <>
                "archiving the corrupt file and starting with zero mappings"
            )

            archive_corrupt_file(path)
            []
        end

      {:error, _} ->
        []
    end
  end

  defp archive_corrupt_file(path) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    archive_path = "#{path}.corrupt.#{timestamp}"

    case File.rename(path, archive_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "GitBridge.Supervisor: failed to archive corrupt #{path} to #{archive_path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp write_mappings(data_dir, mappings) do
    File.mkdir_p!(data_dir)
    json = CanonicalJson.encode(mappings)
    atomic_write(mapping_path(data_dir), json)
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

  defp normalize_mapping(mapping) do
    mapping
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("remote", nil)
    |> Map.put_new("branch", "main")
    |> Map.put_new("interval_ms", 30_000)
  end

  defp server_opts(mapping, store) do
    [
      mount_uuid: mapping["mount_uuid"],
      repo_dir: mapping["repo_dir"],
      store: store,
      remote: mapping["remote"],
      branch: mapping["branch"] || "main",
      interval_ms: mapping["interval_ms"] || 30_000
    ]
  end

  defp child_id(mapping), do: {:git_bridge_server, mapping["repo_dir"]}
end
