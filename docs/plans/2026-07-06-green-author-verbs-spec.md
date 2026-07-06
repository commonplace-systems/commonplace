# CX-vfau (part b) spec — author-facing green verbs + the reactive-exclusivity reference

Author: commonplace (Fable design/review; Sonnet implements). Inputs:
black-channel brief §6 (black senses / green actuates; "the bursar's
acquire/release verbs need an author-facing form callable from compute
docs"), `Commonplace.Green.Bursar`/`BursarClient` (shipped, dogfooded by
Move + TickBot), `Commonplace.Black` M1 (the posture to mirror).

## 1. Scope discipline (what this build is NOT)

CX-vfau names four parts. This build is part (b) ONLY plus one tested
reference composition. The adoption WAVE (deploy locks, experiment
lifecycle, fork TTL, presence slots, MUD bot sessions) is deliberately
deferred until each has a live consumer — adopting a lock nobody holds
is speculation, and MUD edit-locks want CX-lg06 (game-loop signing)
first. The cluster-arbiter design residual (part c) and the docs fold
(part d) are the coordinator's own work, not yours.

## 2. `Commonplace.Green` — the author facade

New module `apps/commonplace/lib/commonplace/green.ex`, the exact peer
of `Commonplace.Black` for the actuator side:

- `acquire(path, holder, opts \\ [])`, `release(path, holder, opts)`,
  `renew(path, holder, opts)`, `query(path, opts)` — thin delegations
  to `Commonplace.Green.BursarClient` (`opts[:server]` override kept).
  Deliberately NOT exposed: `force_release` and `transfer` — break-glass
  and custody-transfer are operator verbs, not author verbs; say so in
  the moduledoc.
- `holder` is REQUIRED and explicit (no ambient default): the moduledoc
  prescribes the convention — a compute doc uses its own code-doc uuid
  (stable across runs → idempotent re-acquire), a session uses its
  session identity. Hands/signing are NOT involved: green custody is
  operational, not security-bearing; a token is not a capability and
  never feeds `Trust.authorized?` (state this, it is the green/white
  boundary).
- `with_token(path, holder, opts, fun)` — the one convenience worth
  adding: acquire → run `fun` → release in `after`, returning
  `{:denied, holder_info}` without running `fun` on contention.
  Author code should rarely hand-sequence acquire/release.
- Trust posture (mirror Black's moduledoc argument): author code only
  reaches this module from execute-gated compute (Gate B), so no new
  trust surface is introduced; the module itself adds no authorization.

## 3. The reference composition (tested example, not new machinery)

One test — `apps/commonplace/test/commonplace/green_test.exs` — whose
final describe block IS the brief-§6 reactive-exclusivity pattern,
composed from shipped parts, no new substrate:

a `Black.PatternCompute` whose `compute_fn` calls
`Green.with_token(claim_path, holder, [ttl: ...], fn -> ... end)` and on
`{:denied, info}` calls `Black.emit_red(doc_uuid, %{...denied...})`.
Assert: first trigger acquires and computes; a second compute (different
holder) racing the same claim path gets denied and the red signal is
observed by a subscriber. Plus plain unit tests for the facade
delegations and `with_token` (release-on-exception included).

Also add a moduledoc "worked example" section showing that composition
as code — this doubles as the docs seed for part (d).

## 4. Constraints

DO NOT SPAWN SUBAGENTS. NEVER use run_in_background — all commands
foreground. No bd/.beads, no push. Composition only: no changes to
bursar.ex / bursar_client.ex / black*.ex / trust anything — if a gap
forces one, STOP and flag. mix compile --warnings-as-errors clean.
Verification: compile → your new tests → mix test apps/commonplace/test
(full core, foreground; note-don't-chase known single flakes:
EntryAgent snapshot-threshold, VersionTracking await, teardown races).
Commit: "CX-vfau: Commonplace.Green author verbs + reactive-exclusivity
reference", Co-Authored-By: Claude Sonnet <noreply@anthropic.com>.
FINAL REPORT: sha, files, counts, flags, pre-existing bugs.
