defmodule Commonplace.MUD.EngineModule do
  @moduledoc """
  CX-2xez (MUD-as-documents Inc-1) — the thin KERNEL resolver that routes an
  engine module through the existing compile-from-doc waist
  (`Commonplace.Code.SourceDoc.compile/3` + Gate B trust-split + the
  hash-keyed compile cache). This is the FIRST slice of self-hosting: the
  command parser's BEHAVIOR runs from a node-signed document, so editing that
  doc hot-reloads the grammar with no redeploy — and (the whole point) a
  deploy becomes a doc-commit, dissolving the escript-vs-serve skew class by
  construction.

  ## What is kernel vs doc-hosted (the BEHAVIOR / DATA-CONTRACT boundary)

  Only BEHAVIOR (functions) is doc-hosted. Shared DATA CONTRACTS
  (`%Commonplace.MUD.Parser.Command{}` — pattern-matched structurally by the
  compiled-in `Verbs`) stay kernel-side. The doc-hosted parser RETURNS the
  kernel-defined `Command`; it does not own it. The compiled-in
  `Commonplace.MUD.Parser` keeps the struct, `parse/1`, and the direction
  helpers (`opposite_direction/1`, `direction?/1`) that compiled-in `Verbs`
  calls directly — those are untouched by Inc-1.

  ## The manifest is a TRUST ROOT (§3/§9 W2)

  `resolve/2` maps an engine NAME (`:parser`) to a doc-uuid via the manifest —
  `Application.get_env(:commonplace, :mud_engine_manifest, %{})`, set by node
  bootstrap, NEVER a player-supplied uuid. If a player could point the
  resolver at their own doc they'd inject engine code; the manifest being
  node/operator-only closes that. It is defense-in-depth over the structural
  guard: `SourceDoc.compile(gate: :execute)` runs **Gate B**
  (`Trust.authorized_to_execute?`) BEFORE compiling, so even a
  manifest-referenced doc whose latest commit is player-signed is REFUSED
  (`{:error, {:execution_denied, _}}`) — a player cannot inject engine code by
  editing the parser doc (§7 W1). Gate B runs verify-time (on cache hits too),
  so a revoked authority stops the next compile (§7 W7).

  ## The non-brick guarantee — two fallback tiers + crash containment (§5)

  A bad engine-doc must NEVER brick the world. `resolve/2` always returns a
  runnable module:

    1. **doc-good** — `SourceDoc.compile` succeeds → that module (and it is
       remembered as last-good for this doc-uuid).
    2. **last-good** — on a compile `{:error}` (syntax/compile failure, or a
       Gate-B rejection), return the last module that compiled for this
       doc-uuid, if any. This is safe against `SourceDoc`'s purge-before-
       recompile: `:code.purge/1` only removes *old* code, never the current
       version, so a failed recompile leaves the previously-loaded module
       still current and callable.
    3. **compiled-in FLOOR** — if no doc version ever compiled (fresh boot,
       doc absent, broken-from-the-start), fall back to the baked-in
       `Commonplace.MUD.Parser`. A DISTINCT module from the doc-hosted one, so
       a doc compile never purges it — it is always available.

  `parse/2` wraps the resolved module's `parse/1` in try/rescue/catch: a
  doc-module that COMPILES but crashes at runtime falls back to
  last-good/floor for that one call (§5.3), never taking down the session or
  world. The ultimate floor is `Parser.parse/1` (compiled-in, correct) — it
  cannot fail on a binary line, so `parse/2` always returns a `%Command{}`.

  ## Perf (Inc-1 accepts, optimization deferred — §4)

  Inc-1 resolves-per-parse to PROVE the path. That runs Gate B (a `Trust`
  walk) on every command — cheap on a `SourceDoc` cache hit but non-trivial on
  a hot path. The deferred optimization is to cache the resolved module and
  invalidate on a doc-change notification (or hash-check on a tick). MUD
  command rates are low (a human types << a few/s; the rate-limiter bounds it)
  so per-parse resolution is fine for Inc-1. Flagged, not built.
  """

  require Logger

  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.Parser
  alias Commonplace.Store.CommitStoreClient

  # Compiled-in FLOOR module per engine name. DISTINCT from any doc-hosted
  # module name, so a `SourceDoc.compile` of the doc never purges it.
  @floor %{parser: Parser}

  @doc """
  Parse `line` through the doc-hosted parser (resolving the current engine
  module), with crash containment. Always returns a
  `%Commonplace.MUD.Parser.Command{}`. This is the thin wrapper the
  `PlayerSession` call site uses in place of `Parser.parse/1`.
  """
  @spec parse(binary(), GenServer.server()) :: Parser.Command.t()
  def parse(line, store \\ CommitStoreClient) when is_binary(line) do
    module = resolve(:parser, store)
    safe_parse(module, line)
  end

  @doc """
  Resolve the current engine module for `name`. Returns a runnable module,
  always: doc-good → last-good (for this doc-uuid) → compiled-in floor. Never
  raises, never returns nil.
  """
  @spec resolve(atom(), GenServer.server()) :: module()
  def resolve(name, store \\ CommitStoreClient) do
    case manifest_uuid(name) do
      nil ->
        # No manifest entry (default, or a not-yet-bootstrapped node) → the
        # floor, silently. NOT an alarm: the doc-hosted path is strictly
        # additive; absence just means "run compiled-in".
        floor_module(name)

      uuid ->
        case SourceDoc.compile(uuid, store, gate: :execute) do
          {:ok, module} ->
            remember_last_good(uuid, module)
            module

          {:error, reason} ->
            alarm(name, uuid, {:compile, reason})
            last_good(uuid) || floor_module(name)
        end
    end
  end

  ## Internals

  # Resolve the manifest map fresh each call (trust root; node-set app-env,
  # never player input). Default empty → floor.
  defp manifest_uuid(name) do
    :commonplace
    |> Application.get_env(:mud_engine_manifest, %{})
    |> Map.get(name)
  end

  defp floor_module(name), do: Map.fetch!(@floor, name)

  # Apply the resolved module's parse/1 with crash containment. A compile-OK
  # but runtime-crashing doc-module falls back to last-good/floor for THIS
  # call. The ultimate floor is Parser.parse/1 (compiled-in, cannot fail on a
  # binary), so this always returns a %Command{}.
  defp safe_parse(module, line) do
    module.parse(line)
  rescue
    e -> parse_fallback(module, line, {:rescue, e})
  catch
    kind, reason -> parse_fallback(module, line, {kind, reason})
  end

  defp parse_fallback(failed_module, line, err) do
    alarm(:parser, nil, {:runtime_crash, failed_module, err})

    # Try any distinct candidate (last-good, then floor); the floor
    # (Parser.parse/1) is the guaranteed terminal — compiled-in + correct.
    floor_mod = floor_module(:parser)

    [last_good_for_parser(), floor_mod]
    |> Enum.reject(&(is_nil(&1) or &1 == failed_module))
    |> Enum.reduce_while(nil, fn candidate, _acc ->
      try do
        {:halt, candidate.parse(line)}
      rescue
        _ -> {:cont, nil}
      catch
        _, _ -> {:cont, nil}
      end
    end)
    |> case do
      nil -> floor_mod.parse(line)
      command -> command
    end
  end

  # last-good is keyed by DOC-UUID (not name): a given doc's last successfully
  # compiled module. Kept in :persistent_term (read-free hot path; written
  # only when the module actually changes, which is rare).
  defp remember_last_good(uuid, module) do
    key = last_good_key(uuid)

    if :persistent_term.get(key, nil) != module do
      :persistent_term.put(key, module)
    end
  end

  defp last_good(uuid), do: :persistent_term.get(last_good_key(uuid), nil)

  defp last_good_for_parser do
    case manifest_uuid(:parser) do
      nil -> nil
      uuid -> last_good(uuid)
    end
  end

  defp last_good_key(uuid), do: {__MODULE__, :last_good, uuid}

  # A doc-module compile failure or a runtime crash is a LOUD event (an
  # engine module fell back) — telemetry + a warn log. The world keeps
  # running on the fallback tier; this makes the degradation observable.
  defp alarm(name, uuid, detail) do
    :telemetry.execute(
      [:commonplace, :mud, :engine_module, :fallback],
      %{count: 1},
      %{name: name, uuid: uuid, detail: detail}
    )

    Logger.warning(
      "EngineModule #{inspect(name)} (#{inspect(uuid)}) fell back to last-good/floor: #{inspect(detail)}"
    )
  end
end
