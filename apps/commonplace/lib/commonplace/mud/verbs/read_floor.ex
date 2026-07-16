defmodule Commonplace.MUD.Verbs.ReadFloor do
  @moduledoc """
  CX-wkau (MUD-as-documents Inc-1, tranche 1) — the compiled-in FLOOR for the
  doc-hosted `read` verb, mirroring `Commonplace.MUD.Verbs.LookFloor`'s role
  for `look` (CX-aya0 / B1). `EngineModule.resolve/2` falls back to this
  module (never purged by a `SourceDoc` recompile — it is a DISTINCT module
  from any doc-hosted `read` module) when no manifest entry is set, when
  the manifest-referenced doc fails Gate B or fails to compile, or (via
  `run_verb/4`'s crash containment) when a compiled doc-module raises at
  runtime.

  `run/2` is a one-line delegator to `Commonplace.MUD.Verbs.do_read/2` (via
  the `__read_floor__/2` escape hatch) — NOT a reimplementation. This means
  the floor can never drift out of parity with the live compiled-in verb:
  there is exactly one implementation of `read`, this just exposes a call
  path into it with the `module.run(cmd, ctx)` shape `EngineModule` expects.
  """

  alias Commonplace.MUD.Parser
  alias Commonplace.MUD.Verbs

  @spec run(Parser.Command.t(), map()) :: term()
  def run(cmd, ctx), do: Verbs.__read_floor__(cmd, ctx)
end
