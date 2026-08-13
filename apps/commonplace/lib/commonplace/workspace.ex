defmodule Commonplace.Workspace do
  @moduledoc """
  Workspace initialization, discovery, and identity helpers — shared across
  the CLI, MCP, and web/core entrypoints.

  A commonplace workspace is any directory containing a `.commonplace/`
  subdirectory. Its helpers include:

  * `discover/1` walks upward from a starting path to the nearest such
    directory, returning the resolved `data_dir` (the `.commonplace/`
    directory itself) and the relative path from that workspace root to
    the original starting directory.
  * `root_uuid/0` reads the workspace's root schema UUID from
    `<data_dir>/root` (`data_dir` from application env).
  * `node_id/0` reads — or atomically creates on first call — the
    persistent per-workspace node-id (CX-njf): a stable string that
    underpins `Identity.stable_client_id/1`. It is workspace-scoped (not
    `node()`-derived) so it survives BEAM restarts without reintroducing
    the state-vector bloat a host-derived id would, while still differing
    between separate installs.
  """

  @workspace_dir ".commonplace"

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Sync.CheckoutRegistry
  alias Commonplace.Tree.Schema

  @doc """
  Initialize a complete workspace through the domain path used by `commonplace
  init`.

  The commit store must already be running against `data_dir`. Creating the
  root commit before writing the `root` prior-world marker is intentional: the
  normal commit builder mints and publishes the node signing identity while
  this is still a genuine first boot. The returned checkout registry is linked
  to the caller, matching the CLI command's lifetime.

  Tests may supply a store pid/name and a contained checkout directory while
  exercising this same path; production init uses the normal store client and
  the directory containing `.commonplace`.
  """
  @spec initialize(Path.t(), keyword()) ::
          {:ok, %{root_uuid: String.t(), checkout_registry: pid()}} | {:error, term()}
  def initialize(data_dir, opts \\ []) when is_binary(data_dir) do
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStore)
    checkout_dir = Keyword.get(opts, :checkout_dir, Path.dirname(data_dir))
    profile = Keyword.get(opts, :profile, :default)
    validate_profile!(profile)
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema() |> Schema.put_workspace_profile(profile)
    update = Yelixer.Encoding.encode_update(root_doc)

    node_context_result =
      case Keyword.fetch(opts, :signing_context) do
        {:ok, context} -> {:ok, context}
        :error -> NodeIdentity.signing_context()
      end

    with {:ok, node_context} <- node_context_result do
      initialize_root(data_dir, checkout_dir, store, root_uuid, update, node_context)
    end
  end

  defp validate_profile!(profile) when profile in [:default, :minimal], do: :ok

  defp validate_profile!(profile) do
    raise ArgumentError,
          "invalid workspace profile #{inspect(profile)}; expected :default or :minimal"
  end

  @doc """
  Read a workspace's recorded class declaration from its root schema.

  `:absent` is the deliberate compatibility result for the closed population
  of legacy workspaces which predate profile recording. A versioned root whose
  profile field is missing returns an error instead of defaulting.
  """
  @spec profile(String.t(), GenServer.server()) ::
          {:ok, :default | :minimal} | :absent | {:error, term()}
  def profile(root_uuid, store \\ CommitStoreClient) when is_binary(root_uuid) do
    case Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, root_uuid) do
      {:ok, root_doc} -> Schema.workspace_profile(root_doc)
      :none -> {:error, :no_root_schema}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_root(data_dir, checkout_dir, store, root_uuid, update, node_context) do
    case CommitStoreClient.create_chained_commit(store, root_uuid, update, %{},
           signing_context: node_context
         ) do
      %Commonplace.Store.Commit{} ->
        with :ok <- File.write(Path.join(data_dir, "root"), root_uuid),
             {:ok, registry} <-
               CheckoutRegistry.start_link(
                 config_path: Path.join(data_dir, "checkouts.json"),
                 store: store
               ),
             {:ok, _checkout} <-
               CheckoutRegistry.register(registry, checkout_dir, root_uuid, :dir) do
          {:ok, %{root_uuid: root_uuid, checkout_registry: registry}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Discover the nearest commonplace workspace at or above `start_dir`.

  Returns `{data_dir, relative_path}` if found, or `nil` if no workspace
  exists anywhere on the path to the filesystem root. `data_dir` is the
  absolute path to the `.commonplace/` directory; `relative_path` is the
  portion of `start_dir` below the workspace root (empty string if
  `start_dir` is the workspace root itself).
  """
  @spec discover(Path.t()) :: {Path.t(), String.t()} | nil
  def discover(start_dir) when is_binary(start_dir) do
    do_discover(start_dir, start_dir)
  end

  defp do_discover(current_dir, original_dir) do
    candidate = Path.join(current_dir, @workspace_dir)

    cond do
      File.dir?(candidate) ->
        relative =
          if original_dir == current_dir do
            ""
          else
            Path.relative_to(original_dir, current_dir)
          end

        {candidate, relative}

      current_dir == "/" ->
        nil

      true ->
        do_discover(Path.dirname(current_dir), original_dir)
    end
  end

  @doc """
  Returns the workspace's root schema UUID by reading `<data_dir>/root`.

  `data_dir` is taken from `Application.get_env(:commonplace, :data_dir, "data")`.
  Returns `{:ok, uuid_string}` or `{:error, reason}`.

  Matches the pattern used by the wiki/tree LiveViews' private
  `read_root_uuid/1` helpers — this is the shared version for code that
  lives in the core `commonplace` app (e.g. `ViewActionDispatch`).
  """
  @spec root_uuid() :: {:ok, String.t()} | {:error, term()}
  def root_uuid do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    case File.read(Path.join(data_dir, "root")) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read (or auto-generate) the persistent per-workspace node-id (CX-njf).

  Returns `{:ok, id}` where `id` is a stable string scoped to the
  current `data_dir`. On first call for a workspace, generates a fresh
  UUID, publishes it create-once (unique temp + hard link) at
  `<data_dir>/node_id` with mode 0o600, and returns it. A racing loser
  reads the winner's value. Subsequent calls re-read that same value.

  This is the prerequisite for derivations like
  `Identity.stable_client_id/1` that previously hashed `{node(), uuid}`
  — `node()` changes across sname renames / IP changes, producing a
  different client_id every restart and reintroducing the state-vector
  bloat CX-6g6 fixed for Presence. A workspace-scoped id is stable
  across BEAM restarts on the same workspace, while still differing
  between separate installs (so two nodes writing to the same logical
  identity get distinct client_ids and Yjs in-memory merge preserves
  both writes).

  Returns `{:error, reason}` only on filesystem errors that prevent
  both reading and creating the file (e.g. data_dir doesn't exist
  yet). Callers that need the id at any cost should fall back to a
  constant when this errors so the system stays writable in degraded
  environments (the bloat is back, but writes don't crash).
  """
  @spec node_id() :: {:ok, String.t()} | {:error, term()}
  def node_id do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    node_id(data_dir)
  end

  @doc "Read or create the node id in an explicitly supplied workspace data directory."
  @spec node_id(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def node_id(data_dir) when is_binary(data_dir) do
    path = Path.join(data_dir, "node_id")

    case File.read(path) do
      {:ok, content} ->
        {:ok, String.trim(content)}

      {:error, :enoent} ->
        write_fresh_node_id(data_dir, path)

      {:error, _} = err ->
        err
    end
  end

  defp write_fresh_node_id(data_dir, path) do
    fresh = UUID.uuid4()
    tmp = Path.join(data_dir, ".node_id.#{node_id_temp_suffix()}.tmp")

    result =
      with :ok <- File.mkdir_p(data_dir),
           :ok <- File.write(tmp, fresh, [:write]),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- link_node_id_into_place(tmp, path),
           :ok <- drop_node_id_temp(tmp),
           {:ok, content} <- File.read(path) do
        {:ok, String.trim(content)}
      end

    _ = File.rm(tmp)
    result
  end

  defp link_node_id_into_place(tmp, path) do
    case File.ln(tmp, path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} = error -> error
    end
  end

  defp drop_node_id_temp(tmp) do
    _ = File.rm(tmp)
    :ok
  end

  defp node_id_temp_suffix do
    rand = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{System.pid()}.#{System.unique_integer([:positive, :monotonic])}.#{rand}"
  end
end
