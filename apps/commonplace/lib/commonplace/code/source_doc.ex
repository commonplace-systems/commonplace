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

  Exception (CX-9f62): when the caller passes `unique_module: key` to
  `compile/3` (only `Commonplace.MUD.VerbSource` does today), the
  top-level `defmodule` alias is rewritten before compiling to a name
  derived from `key` (`Commonplace.MUD.UserVerb.V<sha256 hex>`), so two
  verb docs authored under the identical `defmodule UserVerb` name
  never collide in the BEAM module table. This is scoped to the verb
  path only — `unique_module` absent is byte-for-byte the original
  self-naming behavior.

  ## Cache shape (round-1 audit (A); cache_key generalized in CX-9f62)

  Two ETS tables:
  * `:source_doc_index` — `{uuid, content_hash, cache_key, accessed}` —
    latest hash + derived cache_key per uuid
  * `:source_doc_cache` — `{cache_key → module}` — compiled module

  `cache_key` is the bare `content_hash` unless the caller passed
  `unique_module: key` to `compile/3`, in which case it's `{content_hash,
  key}` — see "Module name source" below.

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

  ## `opts` (CX-9f62)

  `:unique_module` — when present (any term, typically the calling
  doc's own uuid), the source's top-level `defmodule` name is rewritten
  before compiling to a name derived deterministically from this key,
  so distinct callers passing distinct keys never collide in the BEAM
  module table even if their source text uses the identical
  `defmodule` name. Used by `Commonplace.MUD.VerbSource` so two
  same-named `@verb`s on different objects compile to distinct modules
  (fix for the global compile collision / verb-name hijack).

  When `:unique_module` is absent (the default), behavior is UNCHANGED
  from before this option existed: the source's own `defmodule` name is
  used as-is. This is relied on by `Commonplace.View.ComputeRunner` and
  `Commonplace.Process.Orchestrator` — do not change their behavior.

  ## `:gate` (CX-ndvi §1.1 — the gate-class parameterization)

  `:gate` selects WHICH pre-compile authorization walk runs before the
  cache lookup. Two shapes:

    * `:execute` (the default, and the only value before CX-ndvi) —
      unchanged: `Commonplace.Trust.authorized_to_execute?/2` (Gate B).
      Every existing caller (`Commonplace.View.ComputeRunner`,
      `Commonplace.Process.Orchestrator`, and any caller that omits
      `:gate` entirely) takes this path — BYTE-IDENTICAL to the
      pre-CX-ndvi behavior, including the `{:execution_denied, reason}`
      error shape and the `[:commonplace, :code, :rejected, :trust]`
      telemetry event.
    * `{:verb, section_scope}` — a SAFE MUD verb doc is not ambient
      player code (untrusted players never hold `:execute`; the verb
      RUNNER holds it, not the doc). Instead every contributor to the
      verb doc must hold `:define_verb` for `section_scope` (a list of
      anchor uuids — see `Commonplace.Trust.DefineVerbGate` for why the
      anchor is the verb's HOST object/room rather than the verb doc's
      own fresh uuid). Runs
      `Commonplace.Trust.DefineVerbGate.authorized_to_define?/3`
      instead of the execute walk. Used exclusively by
      `Commonplace.MUD.SafeVerb`/`Commonplace.MUD.VerbSource`'s safe-verb
      path — the legacy full-`defmodule` verb path and every other
      caller keep passing no `:gate` (or `:execute` explicitly) and see
      no behavior change whatsoever.

  Both branches share the same cache-lookup/compile/telemetry plumbing
  below them; only the WHICH-check differs.

  `:require_safe_wrapper` (CX-fhz4, default `false`) — when `true`, runs
  `Commonplace.MUD.SafeVerb.Allowlist.check_wrapped/1` against the
  STORED source, before the cache lookup (and so on cache hits too),
  re-verifying both the exact substrate wrapper shape and the body
  allowlist independent of the `.safe.elx` filename. Set only by
  `Commonplace.MUD.SafeVerb.compile/3`; every other caller omits it and
  sees no behavior change.
  """
  @spec compile(binary(), GenServer.server(), keyword()) ::
          {:ok, module()} | {:error, term()}
  def compile(uuid, store \\ CommitStoreClient, opts \\ []) when is_binary(uuid) do
    ensure_tables()

    # Gate B (CX-tdkq.2 / R2) / CX-ndvi §1.1: every commit contributing
    # to a code doc since the trusted baseline must hold the relevant
    # authority for the selected gate class. Runs BEFORE the cache
    # lookup — deliberately on cache hits too — so a trust-config change
    # (revocation) takes effect on the next compile rather than being
    # masked by an already-cached module. This is the narrow waist every
    # execute ingress shares (ComputeRunner and the Orchestrator, which
    # reads source itself and would bypass a gate in read/2) — the
    # `{:verb, _}` gate class reuses this exact waist for :define_verb.
    gate_result =
      case Keyword.get(opts, :gate, :execute) do
        :execute ->
          Commonplace.Trust.authorized_to_execute?(store, uuid)

        {:verb, section_scope} ->
          Commonplace.Trust.DefineVerbGate.authorized_to_define?(store, uuid, section_scope)
      end

    case gate_result do
      :ok ->
        with {:ok, source, hash} <- read(uuid, store),
             :ok <- check_safe_wrapper(uuid, source, opts) do
          case lookup_cached(uuid, hash, opts) do
            {:ok, module} ->
              {:ok, module}

            :miss ->
              purge_stale(uuid)
              do_compile(uuid, source, hash, opts)
          end
        end

      {:error, reason} ->
        :telemetry.execute(
          [:commonplace, :code, :rejected, :trust],
          %{system_time: System.system_time()},
          %{doc_uuid: uuid, reason: reason}
        )

        {:error, {:execution_denied, reason}}
    end
  end

  # CX-fhz4 — the run-boundary re-verification opt-in. Runs BEFORE the
  # cache lookup, deliberately on cache hits too (mirrors the gate check
  # above), so a doc whose stored content isn't the exact substrate
  # wrapper shape (or whose body no longer allowlists) is refused on
  # every compile — not just the first one that populated the cache.
  # Default `false`: every existing caller (ComputeRunner, Orchestrator,
  # the legacy verb path, and any caller that omits the opt) is
  # byte-identical to pre-CX-fhz4 behavior.
  defp check_safe_wrapper(uuid, source, opts) do
    if Keyword.get(opts, :require_safe_wrapper, false) do
      case Commonplace.MUD.SafeVerb.Allowlist.check_wrapped(source) do
        :ok ->
          :ok

        {:error, reason} = err ->
          :telemetry.execute(
            [:commonplace, :code, :rejected, :unsafe_verb],
            %{system_time: System.system_time()},
            %{doc_uuid: uuid, reason: reason}
          )

          err
      end
    else
      :ok
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

  # R8(c) / CX-tdkq.8: bound the compile cache. Edits already reclaim their
  # own old module (purge_stale on hash change), but nothing capped growth
  # across DISTINCT code docs, and a deleted doc's module was never reclaimed
  # — a long-lived substrate accumulated compiled modules without bound. The
  # index table now carries a monotonic last-access stamp so we can evict
  # least-recently-used entries once the cache exceeds the cap. A miss after
  # eviction simply recompiles — correctness is unaffected, it's a cache.
  @default_max_cached_modules 256

  defp max_cached_modules do
    Application.get_env(:commonplace, :source_doc_cache_max, @default_max_cached_modules)
  end

  # Cache key for the compiled-module table. When `:unique_module` is absent
  # (the compute/view/black path), the key is the bare content hash — byte-
  # for-byte identical to pre-CX-9f62 behavior, so identical source text
  # across different docs still shares one compiled module as before.
  #
  # When `:unique_module` is present (the verb path), the key also carries
  # the caller's key so two docs with textually-identical source (e.g. both
  # authored as `defmodule UserVerb`) never share a cache row — each gets
  # its own derived module name (see `derive_module_atom/1`).
  defp cache_key(hash, opts) do
    case Keyword.get(opts, :unique_module) do
      nil -> hash
      key -> {hash, key}
    end
  end

  # index_table rows are {uuid, hash, cache_key, accessed}. Carrying the
  # cache_key alongside the hash (rather than recomputing it from opts)
  # means eviction (which has no access to the original call's opts) can
  # still reclaim the right cache_table row via purge_stale/1.
  defp lookup_cached(uuid, hash, opts) do
    key = cache_key(hash, opts)

    with [{^uuid, ^hash, ^key, _accessed}] <- :ets.lookup(@index_table, uuid),
         [{^key, module}] <- :ets.lookup(@cache_table, key) do
      # Touch on hit so the LRU eviction order reflects real usage.
      :ets.insert(@index_table, {uuid, hash, key, now_ms()})
      {:ok, module}
    else
      _ -> :miss
    end
  end

  defp purge_stale(uuid) do
    case :ets.lookup(@index_table, uuid) do
      [{^uuid, _old_hash, old_key, _accessed}] ->
        case :ets.lookup(@cache_table, old_key) do
          [{^old_key, old_module}] ->
            try do
              :code.purge(old_module)
            rescue
              _ -> :ok
            end

            :ets.delete(@cache_table, old_key)

          [] ->
            :ok
        end

        :ets.delete(@index_table, uuid)

      [] ->
        :ok
    end
  end

  defp do_compile(uuid, source, hash, opts) do
    filename = "docref://" <> uuid

    try do
      [{module, _bin} | _] =
        case Keyword.get(opts, :unique_module) do
          nil ->
            Code.compile_string(source, filename)

          key ->
            ast = Code.string_to_quoted!(source, file: filename, line: 1)
            new_ast = rewrite_module_name(ast, derive_module_atom(key))
            Code.compile_quoted(new_ast, filename)
        end

      cache_key = cache_key(hash, opts)
      :ets.insert(@index_table, {uuid, hash, cache_key, now_ms()})
      :ets.insert(@cache_table, {cache_key, module})
      evict_over_cap()

      {:ok, module}
    rescue
      e -> {:error, {:compile_error, Exception.message(e)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  # Deterministic, collision-free module name derived from an arbitrary key
  # (the verb source doc's own uuid). Same key always derives the same
  # module name, so re-compiling after a content-hash change (hot reload)
  # still targets the same atom — purge_stale/2 above reclaims the old code
  # for that atom before the redefinition, same as the self-named path.
  defp derive_module_atom(key) do
    hex = :crypto.hash(:sha256, to_string(key)) |> Base.encode16(case: :lower)
    String.to_atom("Elixir.Commonplace.MUD.UserVerb.V" <> hex)
  end

  # Rewrites the FIRST top-level `defmodule` alias found (prewalk = top-down,
  # left-to-right) to `new_alias_atom`, leaving everything else (including
  # any nested defmodule, which already has a distinct name) untouched. A
  # source doc with no defmodule at all is a no-op here; the subsequent
  # `Code.compile_quoted/2` then returns `[]` and the `[{module,_}|_] = `
  # match raises, caught by the `rescue` in `do_compile/4` same as today.
  defp rewrite_module_name(ast, new_alias_atom) do
    {new_ast, _found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, meta, [_old_alias, body]}, false ->
          {{:defmodule, meta, [{:__aliases__, [alias: false], [new_alias_atom]}, body]}, true}

        node, found? ->
          {node, found?}
      end)

    new_ast
  end

  # Strictly monotonic access stamp. Millisecond wall-time ties (several
  # compiles inside one ms) made LRU eviction order arbitrary — the
  # sort_by in evict_over_cap broke ties by ETS table order, evicting
  # recently-touched entries under load (flaky R8c cap test).
  defp now_ms, do: :erlang.unique_integer([:monotonic])

  # Evict least-recently-used entries until the cache is back within the cap.
  # Keyed off the index table (one entry per uuid); purge_stale/1 reclaims the
  # module, the cache row, and the index row together.
  defp evict_over_cap do
    cap = max_cached_modules()

    if :ets.info(@index_table, :size) > cap do
      @index_table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_uuid, _hash, _cache_key, accessed} -> accessed end)
      |> Enum.drop(-cap)
      |> Enum.each(fn {uuid, _hash, _cache_key, _accessed} -> purge_stale(uuid) end)
    end

    :ok
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
