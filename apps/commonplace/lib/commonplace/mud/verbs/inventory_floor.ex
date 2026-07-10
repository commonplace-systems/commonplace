defmodule Commonplace.MUD.Verbs.InventoryFloor do
  @moduledoc """
  CX-aya0 (MUD-as-documents Inc-2 / B2) — the compiled-in FLOOR for the
  doc-hosted `inventory` verb, mirroring `Commonplace.MUD.Verbs.LookFloor`'s
  role for `look` (CX-aya0 / B1). `EngineModule.resolve/2` falls back to this
  module (never purged by a `SourceDoc` recompile — it is a DISTINCT module
  from any doc-hosted `inventory` module) when no manifest entry is set, when
  the manifest-referenced doc fails Gate B or fails to compile, or (via
  `run_verb/4`'s crash containment) when a compiled doc-module raises at
  runtime.

  `run/2` is a one-line delegator to `Commonplace.MUD.Verbs.do_inventory/1`
  (via the `__inventory_floor__/2` escape hatch) — NOT a reimplementation.
  This means the floor can never drift out of parity with the live
  compiled-in verb: there is exactly one implementation of `inventory`, this
  just exposes a call path into it with the `module.run(cmd, ctx)` shape
  `EngineModule` expects.
  """

  alias Commonplace.MUD.Parser
  alias Commonplace.MUD.Verbs

  @spec run(Parser.Command.t(), map()) :: term()
  def run(cmd, ctx), do: Verbs.__inventory_floor__(cmd, ctx)
end
