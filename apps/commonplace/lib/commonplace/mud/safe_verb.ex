defmodule Commonplace.MUD.SafeVerb do
  @moduledoc """
  CX-ndvi §3/§4 — the SAFE verb authoring + execution path: a NEW path
  ALONGSIDE the existing full-`defmodule` `Commonplace.MUD.VerbSource`
  path (§4 migration boundary — legacy verbs are UNCHANGED, see that
  module's moduledoc). Where a legacy verb author writes a complete
  `defmodule ... do def run(ctx) ... end end` with an ambient
  `CommitStoreClient`-backed `ctx`, a SAFE verb author writes a bare
  `run/1` BODY — no `defmodule`, no store, no raw uuids — and the
  substrate:

    1. lints the body (`Commonplace.MUD.SafeVerb.Lint` — defense in
       depth, not containment);
    2. wraps it in a substrate-named module (reusing CX-9f62's
       `unique_module` naming so two safe verbs never collide even
       under the identical placeholder module name);
    3. compiles it through `Commonplace.Code.SourceDoc.compile/3` with
       the `{:verb, section_scope}` gate (CX-ndvi §1.1) instead of
       `:execute` — a verb doc's contributors must hold `:define_verb`
       for the verb's host section, not player `:execute`;
    4. runs it bound to ONLY a `Commonplace.MUD.World.Facade` (`world`)
       and `args` — under `Commonplace.MUD.SafeVerb.Bounds` (timeout +
       heap-kill).

  ## HONESTY BOUNDARY

  See `Lint`'s and `Facade`'s moduledocs — both apply here unchanged:
  facade = least-authority, lint = raised bar, NEITHER is hostile-code
  containment. OS-level isolation (phase-4) is the horizon for true
  containment; this module does not claim it.

  ## Wrapping mechanism (why no SourceDoc changes beyond the gate)

  The WRAPPED (full-module) source text is what gets stored as the
  verb doc's content — `wrap_and_lint/1` lints the RAW body (so
  `defmodule` in the author's own text is caught) and then produces:

      defmodule Commonplace.MUD.SafeVerbBody do
        def run(world, args) do
          <body>
        end
      end

  This keeps `Commonplace.Code.SourceDoc.compile/3` completely
  unaware that anything is different about a safe verb beyond the
  `:gate` option (CX-ndvi §1.1's ONE substrate-parameterization change)
  — it reads/hashes/compiles this wrapped text exactly like any other
  code doc, including the existing `unique_module:` collision-free
  naming. `run/2`'s only bindings are its own two parameters — the
  body has no access to `store`, `ctx`, or anything else not passed as
  `world`/`args` (structural — see pin 7 in the build spec and the
  `no_leaked_bindings` test in `SafeVerbTest`).
  """

  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.SafeVerb.{Bounds, Lint}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStoreClient

  @placeholder_module "Commonplace.MUD.SafeVerbBody"

  @doc false
  @spec placeholder_module() :: String.t()
  def placeholder_module, do: @placeholder_module

  @doc """
  Lint the raw `run/1` BODY text and, if clean, wrap it into full
  module source ready to store as a verb doc's content. Returns
  `{:ok, wrapped_source}` or `{:error, {:lint_violation, reasons}}` /
  `{:error, {:lint_syntax_error, message}}`.
  """
  @spec wrap_and_lint(String.t()) :: {:ok, String.t()} | {:error, term()}
  def wrap_and_lint(body) when is_binary(body) do
    case Lint.check(body) do
      :ok -> {:ok, wrap(body)}
      {:error, _} = err -> err
    end
  end

  defp wrap(body) do
    """
    defmodule #{@placeholder_module} do
      def run(world, args) do
    #{body}
      end
    end
    """
  end

  @doc """
  Compile an already-saved safe-verb source doc (`source_uuid`) under
  the `{:verb, section_scope}` gate (CX-ndvi §1.1). Returns
  `{:ok, module}` or `{:error, reason}` — `{:error, {:execution_denied,
  reason}}` on a `:define_verb` gate denial (same error shape Gate B
  uses for `:execute` denials — `SourceDoc.compile/3` doesn't
  distinguish the gate class in its error shape, only in which check ran).

  CX-fhz4 — the RUN-BOUNDARY re-check: passes `require_safe_wrapper:
  true` to `SourceDoc.compile/3`, so on EVERY compile (cache hit or
  miss) the STORED content is structurally re-verified as the exact
  substrate wrapper `wrap/1` produces and its body is re-run through
  `Allowlist.check_wrapped/1`'s allowlist scan. Before this, only the
  `.safe.elx` FILENAME distinguished a safe verb from legacy — a doc
  whose content diverged from that shape (hand-edited, replayed from a
  stale/foreign commit, etc.) would still compile and run under the
  facade. Now compilation itself refuses anything that isn't the
  verified wrapper shape with an allowlisted body, independent of how
  the doc got its name.
  """
  @spec compile(String.t(), [String.t()], GenServer.server()) :: {:ok, module()} | {:error, term()}
  def compile(source_uuid, section_scope, store \\ CommitStoreClient) when is_list(section_scope) do
    SourceDoc.compile(source_uuid, store,
      unique_module: source_uuid,
      gate: {:verb, section_scope},
      require_safe_wrapper: true
    )
  end

  @doc """
  Run a compiled safe-verb `module` bound to `facade` (a
  `%Commonplace.MUD.World.Facade{}`) and `args`, under execution bounds.

  Returns `{:ok, return_value}`, `{:error, :timeout}`,
  `{:error, {:runtime_error, message}}` (includes heap-kill, which
  surfaces as a `:killed` exit reason formatted by `Bounds`), or
  `{:error, {:no_run_export, module}}` if the module doesn't export
  `run/2` (should not happen for anything compiled via `compile/3`
  above, but checked defensively since a caller could pass an arbitrary
  module).
  """
  @spec run(module(), Facade.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def run(module, %Facade{} = facade, args \\ %{}) when is_atom(module) do
    if function_exported?(module, :run, 2) do
      # CX-r8vp — the verb must NEVER reach signing material OR any other
      # capability/identity/store field. Install the FULL facade as the
      # process-side BACKING in the Bounds child's process dict (which verb
      # code can't read — `Process.*` is allowlist-banned) and hand the verb a
      # THIN HANDLE (`to_verb_facing/1`) whose sensitive fields are all nil.
      # The facade's own methods recover the backing via `unwrap/1`. This
      # generalizes the P0 signer-material move to the whole facade. `facade`
      # is captured in THIS closure, not in anything the verb receives.
      Bounds.run(fn ->
        Facade.install_backing(facade)
        invoke(module, Facade.to_verb_facing(facade), args)
      end)
      |> normalize()
    else
      {:error, {:no_run_export, module}}
    end
  end

  defp invoke(module, facade, args) do
    {:__safe_verb_ok__, apply(module, :run, [facade, args])}
  rescue
    e -> {:__safe_verb_error__, {:runtime_error, Exception.message(e)}}
  catch
    kind, reason -> {:__safe_verb_error__, {:runtime_error, "#{kind}: #{inspect(reason)}"}}
  end

  defp normalize({:ok, {:__safe_verb_ok__, val}}), do: {:ok, val}
  defp normalize({:ok, {:__safe_verb_error__, reason}}), do: {:error, reason}
  defp normalize({:error, _} = err), do: err
end
