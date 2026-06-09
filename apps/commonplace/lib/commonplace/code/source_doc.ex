defmodule Commonplace.Code.SourceDoc do
  @moduledoc """
  CX-i27x (sub-bead i of CX-6on8 M6): substrate-tier compile-from-doc
  primitive. Read + compile + cache Elixir source from commonplace
  docs. Generalizes `Commonplace.Process.Orchestrator`'s
  `hot_reload_module/2` + `start_process/2` (`:elixir` mode) compile
  core for substrate consumption (ComputeSpec, future consumers).

  ## Worked end-to-end example (round-1 audit (C))

  A renderer source-doc lives at `/chat/__template/_renderer.ex`. Body
  (full Elixir source, source author self-names with `defmodule`):

      defmodule Commonplace.UserCode.Chat.Renderer do
        def build_view_xml(messages, room_name) do
          # ... XML construction ...
        end
      end

  A spec doc at `/chat/__template/_compute` references the renderer:

      <compute-spec schema="1">
        <pipeline>
          ...
          <step kind="render">
            <function ref="../_renderer.ex" name="build_view_xml"/>
          </step>
        </pipeline>
      </compute-spec>

  Substrate flow:
      ComputeSpec.validate → SourceDoc.resolve("../_renderer.ex", "/chat/__template/_compute", store)
        → walk path → resolve sibling _renderer.ex UUID
        → SourceDoc.compile(uuid, store)
        → Code.compile_string(source, "docref://" <> uuid)
        → returns Commonplace.UserCode.Chat.Renderer module atom
      ViewCompute then `apply(module, :build_view_xml, [input, room_name])`

  ## Module name source (held position #2 + #4)

  Source author self-names via `defmodule X do ... end`. Substrate
  doesn't wrap; compiles the source as-is. Convention:
  `Commonplace.UserCode.<Domain>.<Name>`. Source author owns module
  identity.

  ## Cache shape (round-1 audit (A))

  Two ETS tables:
  * `:source_doc_index` — `{uuid → content_hash}` — latest hash per uuid
  * `:source_doc_cache` — `{content_hash → module}` — compiled module

  Compile flow:
  1. Read source + content_hash from doc
  2. Lookup latest hash for uuid in :source_doc_index
  3. If same as current hash → cache hit; return cached module
  4. Else → purge old module via `:code.purge/1` + delete old entries +
     compile via `Code.compile_string(source, filename)` + insert new
     entries

  O(1) stale cleanup; no memory leak from stacked stale entries.

  ## Stacktrace debuggability (audit Q1)

  `Code.compile_string/2` second arg is the filename. We pass
  `"docref://" <> uuid` so error stacktraces point at the doc. Future
  enhancement: include the doc's path in the filename for richer
  formatting.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Lookup}

  @index_table :source_doc_index
  @cache_table :source_doc_cache

  @doc """
  Read source-doc content + content-hash by UUID.

  Returns `{:ok, source_string, content_hash}` or `{:error, reason}`.
  Reasons: `:not_found` | other.
  """
  @spec read(binary(), GenServer.server()) ::
          {:ok, binary(), binary()} | {:error, term()}
  def read(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} ->
        case ContentType.get_content(doc) do
          nil ->
            {:error, :not_found}

          content when is_binary(content) ->
            {:ok, content, :erlang.md5(content)}
        end

      :none ->
        {:error, :not_found}
    end
  end

  @doc """
  Compile source-doc into a runtime module. Returns `{:ok, module_atom}`
  or `{:error, reason}`.

  Caches by uuid; recompiles only if content_hash changes (round-1
  audit (A) ETS invalidation discipline). Source body is full
  `defmodule X do ... end` — substrate compiles as-is.
  """
  @spec compile(binary(), GenServer.server()) ::
          {:ok, module()} | {:error, term()}
  def compile(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    ensure_tables()

    with {:ok, source, hash} <- read(uuid, store) do
      case lookup_cached(uuid, hash) do
        {:ok, module} ->
          {:ok, module}

        :miss ->
          purge_stale(uuid)
          do_compile(uuid, source, hash)
      end
    end
  end

  @doc """
  Resolve a DocRef to a compiled module. Reads the source-doc reachable
  from `context_path` via `ref`, then compiles it.

  ref examples (note both leading forms currently resolve *identically*):
    `"../_renderer.ex"` — a sibling doc in context_path's containing dir
    `"./_local.ex"` — likewise, a doc in that same containing dir

  `context_path` names a *doc* (a file, e.g.
  `/chat/__template/_compute`), so resolution strips the single leading
  `../` or `./` and joins the remainder onto `Path.dirname(context_path)`.
  Both prefixes therefore land in the same containing directory — `../`
  does **not** climb to the grandparent here. (This mirrors M3
  ArgResolver's `from="../_messages"` shape.)

  Full DocRef (`docref://path:uuid@cid`) is deferred to a future
  milestone; recognized but unimplemented in M6a.

  Returns `{:ok, module_atom}` or `{:error, reason}`.
  """
  @spec resolve(String.t(), String.t(), GenServer.server()) ::
          {:ok, module()} | {:error, term()}
  def resolve(ref, context_path, store \\ CommitStoreClient)
      when is_binary(ref) and is_binary(context_path) do
    with {:ok, target_path} <- resolve_relative(ref, context_path),
         {:ok, root_uuid} <- Commonplace.Workspace.root_uuid(),
         {:ok, target_uuid} <-
           Lookup.lookup_doc_by_path(root_uuid, target_path, store: store) do
      compile(target_uuid, store)
    end
  end

  @doc """
  Test helper: clear both ETS tables. Called from setup/on_exit so
  tests don't leak module cache between runs.
  """
  def reset_cache do
    ensure_tables()
    :ets.delete_all_objects(@index_table)
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  # --- Private ---

  defp ensure_tables do
    case :ets.whereis(@index_table) do
      :undefined ->
        :ets.new(@index_table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end

    case :ets.whereis(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end

    :ok
  end

  defp lookup_cached(uuid, hash) do
    with [{^uuid, ^hash}] <- :ets.lookup(@index_table, uuid),
         [{^hash, module}] <- :ets.lookup(@cache_table, hash) do
      {:ok, module}
    else
      _ -> :miss
    end
  end

  defp purge_stale(uuid) do
    case :ets.lookup(@index_table, uuid) do
      [{^uuid, old_hash}] ->
        case :ets.lookup(@cache_table, old_hash) do
          [{^old_hash, old_module}] ->
            try do
              :code.purge(old_module)
            rescue
              _ -> :ok
            end

            :ets.delete(@cache_table, old_hash)

          [] ->
            :ok
        end

        :ets.delete(@index_table, uuid)

      [] ->
        :ok
    end
  end

  defp do_compile(uuid, source, hash) do
    filename = "docref://" <> uuid

    try do
      [{module, _bin} | _] = Code.compile_string(source, filename)

      :ets.insert(@index_table, {uuid, hash})
      :ets.insert(@cache_table, {hash, module})

      {:ok, module}
    rescue
      e -> {:error, {:compile_error, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  # --- Path resolution ---

  # `../{name}` from a doc path (e.g. /chat/general/_compute) resolves
  # to a SIBLING doc in the same containing directory — same shape as
  # M3 ArgResolver's `from="../_messages"`. Path.dirname of the spec
  # path gives the containing dir; join with the rest gives the
  # sibling path.
  defp resolve_relative("../" <> rest, context_path) do
    parent = Path.dirname(context_path)

    target =
      case parent do
        "." -> rest
        "" -> rest
        _ -> Path.join(parent, rest)
      end

    {:ok, target}
  end

  # `./{name}` is a no-op — same as bare `{name}` in the spec's dir.
  # Kept for symmetry; not currently used by ComputeSpec.
  defp resolve_relative("./" <> rest, context_path) do
    parent = Path.dirname(context_path)

    target =
      case parent do
        "." -> rest
        "" -> rest
        _ -> Path.join(parent, rest)
      end

    {:ok, target}
  end

  defp resolve_relative("docref://" <> _, _context_path) do
    {:error, :full_docref_deferred}
  end

  defp resolve_relative(other, _context_path) do
    {:error, {:unsupported_ref_form, other}}
  end
end
