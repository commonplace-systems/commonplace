defmodule Commonplace.MUD.EngineSeedLintTest do
  @moduledoc """
  CX-wkau (MUD-as-documents Inc-1, tranche 3) — the tranche-3 NO-ELEVATION
  invariant (jes-gated design): TRUST-ADJACENT verbs (`go`/`home`) move
  player presence through `Verbs.invoker_move_opts/1`, built from the
  INVOKING SESSION's own `signing_context`/`cert_cids` — never node
  authority. A doc-hosted seed that constructed its OWN elevated signing
  context (`Commonplace.Crypto.NodeIdentity`) or hand-built a
  `signing_context:` keyword literal would silently grant itself write/move
  authority beyond the invoker's own, defeating the "worst case a doc acts
  as the invoker" contract every seed in this cohort is supposed to honor.

  This is a STATIC source-text lint over every `priv/engine_verbs/*.exs.seed`
  file — not a runtime check — because the whole point is that these
  sources must never even ATTEMPT to reach for node authority: opts/ctx may
  only be threaded through via public helpers (`Verbs.invoker_move_opts/1`,
  `write_opts`-shaped ctx fields already resolved by the session). A seed
  that needs elevation has a boundary bug, not a missing-promotion bug —
  the design draws this line at write time (kernel-side movers/possession
  ops), not at review time.
  """
  use ExUnit.Case, async: true

  @seeds_dir Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs"])

  test "no engine-verb seed constructs an elevated signing context" do
    seed_files =
      @seeds_dir
      |> Path.join("*.exs.seed")
      |> Path.wildcard()

    assert seed_files != [], "expected to find *.exs.seed files under #{@seeds_dir}"

    for path <- seed_files do
      source = File.read!(path)
      name = Path.basename(path)

      refute source =~ "NodeIdentity",
             "#{name}: seeds must never construct elevated signing contexts " <>
               "(references Commonplace.Crypto.NodeIdentity) — the tranche-3 " <>
               "no-elevation invariant"

      refute source =~ "signing_context:",
             "#{name}: seeds must never hand-build a signing_context: keyword " <>
               "literal — opts/ctx may only be threaded through via public " <>
               "helpers (e.g. Verbs.invoker_move_opts/1) — the tranche-3 " <>
               "no-elevation invariant"
    end
  end
end
