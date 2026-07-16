defmodule Commonplace.MUD.Verbs.GoFloor do
  @moduledoc """
  CX-wkau (MUD-as-documents Inc-1, tranche 3) — the compiled-in FLOOR for the
  doc-hosted `go` verb, mirroring `Commonplace.MUD.Verbs.WhereFloor`'s role
  for `where` (tranche 1). `EngineModule.resolve/2` falls back to this
  module (never purged by a `SourceDoc` recompile — it is a DISTINCT module
  from any doc-hosted `go` module) when no manifest entry is set, when the
  manifest-referenced doc fails Gate B or fails to compile, or (via
  `run_verb/4`'s crash containment) when a compiled doc-module raises at
  runtime.

  TRUST-ADJACENT (CX-avzp): `go` moves the player's presence through
  `World.move_presence/5`, the read-gated chokepoint. The floor guarantee
  matters here more than anywhere else in this tranche — a bad doc must
  never brick or bypass the movement gate, only ever fall back to this
  exact compiled-in behavior.

  `run/2` is a one-line delegator to `Commonplace.MUD.Verbs.do_go/2` (via
  the `__go_floor__/2` escape hatch) — NOT a reimplementation. This means
  the floor can never drift out of parity with the live compiled-in verb:
  there is exactly one implementation of `go`, this just exposes a call
  path into it with the `module.run(cmd, ctx)` shape `EngineModule` expects.
  """

  alias Commonplace.MUD.Parser
  alias Commonplace.MUD.Verbs

  @spec run(Parser.Command.t(), map()) :: term()
  def run(cmd, ctx), do: Verbs.__go_floor__(cmd, ctx)
end
