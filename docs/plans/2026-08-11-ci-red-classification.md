# CI-red enumeration, phase (b): classification over the phase-a table

Basis: the phase-a evidence table (`docs/plans/2026-08-11-ci-red-enumeration-measurement.md`,
raw logs under `docs/measurements/2026-08-11-ci-red/`) plus CI's own identity
list (`bin/cp-ci-failures`, last 40 main runs) and run colors since 20:04Z.

## The headline: the population is not a pool, and CI has flipped green

- LOCAL (3 umbrella seeds × 4,352 tests, quiet box, serve down): exactly ONE
  red identity, deterministic in all seeds and alone. Everything else green
  three times. The suite-reliability arc's work has landed measurably.
- CI (last 40 main runs): 27 red / 11 green — but 25 of the 27 reds are ONE
  identity, `TrustConfigFailClosedTest`, last seen 18:54Z, killed by the
  CX-8wh1 merge (@6567f94, ~20:04Z). Since that merge: 9 of 10 completed
  runs GREEN. ⛔ **The standing rule "red-by-run is that pipeline's normal
  state, neither color carries information" is NOW STALE** — it was true
  when coined and its basis was removed at 20:04Z tonight. A red on main is
  once again a signal worth reading. (The unmaintained-claim class: true
  statements that become false without anyone editing them.)

## The classification, per identity

1. **`Yelixer.DiffYjsTest` setup_all `ERR_MODULE_NOT_FOUND` → 11 tests
   INVALIDATED, summary "0 failures", rc=2** — the local sole red.
   - Family: environment/dependency gating. The yjs oracle driver (node
     module) is absent in a fresh worktree; `setup_all` crashes instead of
     the guard skipping.
   - ⛔ NOT CI's red: DiffYjsTest appears nowhere in CI's 40-run identity
     list. The local enclosure (sandboxed worktree, no node_modules) does
     not match CI, and the comparison was run precisely to catch this —
     hypothesis refuted by its own check.
   - This is CX-3mj2's closed territory: that fix's acceptance said the
     skip guard must check THE IMPORT RESOLVES, and assert 11 RAN when
     present. Import-resolution failure in a fresh worktree invalidates
     instead of skipping ⇒ the guard doesn't cover this path (or
     regressed). Fix-shaped, small, Sol-sized. The reconciliation lesson
     rides along: "invalid" tests report "0 failures" with rc≠0 — a red
     that names no failing test — so the fix's red-first must assert the
     INVALID count, not the failure count.
2. **`TrustConfigFailClosedTest` (25 CI occurrences)** — closed by CX-8wh1
   @6567f94; post-merge CI confirms. No action; recorded as the resolved
   dominant.
3. **`HumanWebPlayTest` greet-race (2 CI occurrences, last 20:15Z)** — the
   known CX-5e8s residual, load class, green in isolation. Standing ticket;
   no new action from this measurement.
4. **`SnapshotWorkerTest` / `HotReloadTest` (1 CI occurrence, b577ada @
   22:36Z)** — process-timing class, single draw, green in every run since.
   Recorded as an identity; not chased (one draw is one draw).
5. **The 02:45Z batch** (Bd verb tests, ~20 identities, one run) — a single
   contaminated run pre-dating tonight's fixes; all green since. Recorded,
   not chased.

## Fix-shaped outputs (the pipeline's next Sol briefs)

- CX-z0sa: already authored (`docs/plans/2026-08-11-cx-z0sa-shim-confirmation-brief.md`),
  dispatches post-window.
- NEW ticket to file: the DiffYjs invalidation shape (item 1) — brief to be
  authored as the following buffer item.
- No fix arises from items 2-5.
