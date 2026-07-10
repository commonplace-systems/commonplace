defmodule Commonplace.MUD.Verbs.LookFloor do
  @moduledoc """
  CX-aya0 (MUD-as-documents Inc-2 / B1) — the compiled-in FLOOR for the
  doc-hosted `look` verb, in the same role `Commonplace.MUD.Parser` plays for
  the doc-hosted parser (CX-2xez Inc-1). `EngineModule.resolve/2` falls back
  to this module (never purged by a `SourceDoc` recompile — it is a DISTINCT
  module from any doc-hosted `look` module) when no manifest entry is set,
  when the manifest-referenced doc fails Gate B or fails to compile, or (via
  `run_verb/4`'s crash containment) when a compiled doc-module raises at
  runtime.

  `run/2` is a one-line delegator to `Commonplace.MUD.Verbs.do_look/2` (via
  the `__look_floor__/2` escape hatch) — NOT a reimplementation. This means
  the floor can never drift out of parity with the live compiled-in verb:
  there is exactly one implementation of `look`, this just exposes a call
  path into it with the `module.run(cmd, ctx)` shape `EngineModule` expects.
  """

  alias Commonplace.MUD.Parser
  alias Commonplace.MUD.Verbs

  @spec run(Parser.Command.t(), map()) :: term()
  def run(cmd, ctx), do: Verbs.__look_floor__(cmd, ctx)
end
