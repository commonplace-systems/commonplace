# BUILD BRIEF — CX-8wh1: the complete-workspace fixture helper

**For:** Sol (codex) · **plan's #1 (suite reliability), class 1 — the build half**
**Worktree:** `/home/jes/sol-8wh1/wt` · **branch:** `sol/cx-8wh1-helper`
**Run log:** `/home/jes/sol-8wh1/sol-run.log`

**DISPATCH-READY** (holds only for the CX-5gkw lane to free). Plan ratified
the CX-vvbh posture 2026-08-10 17:01 and recorded @95abb38 that **CX-a2eb's
gate is now ONLY this helper** — §2c carries the ruling.

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ **UNSTAGED** only — no `git
add`, no commit, no push. ⛔ **No serve, no live store** (live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, process-derived).
⚠️ `mix deps.get` first. ⚠️ rc from the command itself, never through a pipe.
⛔ **NO BARE ZEROS.** ⛔⛔ **:4002 pre-flight before every suite run** (umbrella
runs are mutually exclusive on this box):

```bash
h=$(ss -ltnp 2>/dev/null | grep -c ":4002"); [ "$h" -eq 0 ] || { echo "ABORT: :4002 busy"; exit 3; }
```

⭐ **ESCAPE HATCH:** if the population or the remedy does not fit what you
measure, report it and stop.

## 1. The defect class — TWO measured instances, ONE ruled fix

Test fixtures across the umbrella hand-assemble partial `data_dir`s — a
`trust.json` here, a `root` file there — and every trust-layer hardening since
`a4e708d` has found a new subset of them incomplete:

- **CX-a2eb**: `TrustConfigFailClosedTest`'s fixture has no
  `node_signing_public_keys.json` → `public_keys/0` returns `:absent` → node
  self-trust silently dropped → **the suite's only DETERMINISTIC red** (0.4s
  isolated, `cp-ci-failures` #1 with 12 occurrences). Same class already fixed
  once at `901d91b` (reflog snapshot fixture).
- **CX-8wh1 original**: `MudLiveTest` fixtures carry prior-world evidence
  (`root` file) but no `node_signing_key`, so the `0053a8c` mint-refusal
  fired → 11 tests, 10 failures, bisected not assumed. ⚠️ **TIMELINE
  CORRECTION (2026-08-10 18:51, found by Sol's escape-hatch stop): `0053a8c`
  was REVERTED at `85f8990` the same night ("43 fixtures model the state it
  rejects"), so MudLiveTest is GREEN on today's main — 11/0, verified.** The
  ticket's disposition option 1 was taken: *revert, then re-land WITH the
  fixture fix.* **This brief IS that re-land** — see §2d.
- **CX-k2yr** (side effect, fixed by this for free): fixtures lacking the
  public-key artifact make CX-vvbh's degraded-state error line fire ~3,500
  times PER suite run, burying real errors.

⭐ **plan's standing ruling: ONE complete-workspace fixture helper is the fix
for the whole class. ⛔ NEVER per-fixture hand-seeding — someone hand-fixing
one fixture and calling the class done is the named failure mode.**

## 2. The deliverable

### 2a. The helper — complete BY CONSTRUCTION, not by checklist

A test-support function (in `apps/commonplace`'s test support, reachable from
the other apps' suites) that yields a workspace `data_dir` containing
**everything the real initialisation path produces** — signing key, published
public-key artifact, root/prior-world markers, store layout.

⭐ **The required property: the helper CALLS THE REAL WORKSPACE-CREATION CODE
PATH** (the same functions `init` runs), rather than writing files it believes
init would write. A hand-assembled "complete" fixture is this defect with
extra steps — the next artifact added to init recreates the class. If the real
path cannot be called in-test for a reason you can name, that is a §0-escape
finding, not a licence to hand-assemble.

The helper must also accept deliberate DEGRADATION for tests that are ABOUT
incomplete worlds (e.g. delete-the-artifact, corrupt-trust.json options), so
those tests state their precondition explicitly instead of inheriting it from
a bare fixture.

### 2b. The populations — converted, with a denominator built from what ARRIVED

1. **Enumerate first, convert second.** Grep the umbrella's test files for
   fixtures that fabricate a `data_dir`/workspace by hand (writers of
   `trust.json`, `node_signing_key`, `root`, bare `File.mkdir_p` +
   `put_env(:data_dir, ...)` shapes). **Report the full list with per-hit
   file:line — the count is the denominator and prior measurement said ~44 in
   the `node_signing_key` class alone; a small number means your enumeration
   missed, not that the class shrank.**
2. Convert the two MEASURED populations completely: the `MudLiveTest` fixtures
   (all 10 red tests must go green **because the world is complete**, not
   because the refusal was weakened) and `TrustConfigFailClosedTest` per §2c.
3. For the remaining enumerated fixtures: convert those whose tests do not
   depend on incompleteness; leave-and-list any that deliberately test a
   degraded world (converting them to the helper's explicit degradation
   options is in scope where mechanical).

### 2c. The TrustConfigFailClosed assertion — RULED, and the ruling means: DO NOT CHANGE IT

**Plan's ratified posture (2026-08-10 17:01, verified against
`trust.ex:1177-1226`, queue @95abb38): loud-degrade-and-continue** — when
self-trust cannot be folded, every producer outcome (identity-error /
`:absent` / `{:error,_}` / `{:ok,[]}` / catch-all) emits a named
`Logger.error`, the trusted set is unchanged, and startup stays available.

⇒ **What this means for the test, so you don't have to interpret:** its
failing assertion —
`assert Map.keys(cfg.trusted_identities) == [node_identity]` — already
asserts the ratified posture's HEALTHY path: corrupt `trust.json` ⇒ strict
with zero pins, node self-trust folded **when the world is complete**. The
fixture's missing artifact was the defect, not the assertion.

- ⛔ **The assertion stays byte-identical.** The test goes green because the
  helper completes its world, citing this ruling.
- The DEGRADED case (absent artifact ⇒ loud error + trusted set unchanged) is
  already covered by `trust/self_trust_visibility_test.exs` — do not
  duplicate it here.
- ⭐ **The still-can-fail control**: degrade the world once (the helper's
  delete-the-artifact option), show the ORIGINAL assertion go red
  (`left: []`), paste it, restore. ⛔ A `!= nil`-shaped loosening is the
  failure mode this ticket exists to prevent.

### 2d. RE-LAND the mint refusal — the gate lands WITH its cleanup

The refusal (`load_or_mint_keypair` refuses to mint a replacement identity
when prior-world evidence exists and no signing key does) is **ruled correct
by its own revert commit** and is currently ABSENT from main. Re-land it in
THIS branch, so the gate and the fixture fix merge together — a gate landing
before its cleanup is the named failure mode that broke 41 tests once already.

- Semantics per `0053a8c` (read the commit), **reimplemented against the
  CURRENT mint code** — `4af73c5` (CX-37d9) rewrote the mint to
  hard-link-into-place today, so a mechanical cherry-pick will conflict;
  the refusal check belongs BEFORE any mint attempt, unchanged in meaning.
- Restore the refusal's unit tests (the revert deleted 33 test lines from
  `crypto/node_identity_test.exs`; adapt, don't resurrect blindly).
- ⭐ **Red-first for the Mud population is CONSTRUCTED, not inherited: after
  re-applying the refusal and BEFORE converting fixtures, isolated
  `MudLiveTest` must show the 10 MatchError reds** (quote one:
  `{:error, {:node_signing_key_absent, :prior_world_present}}` at
  `signing_context!/1`). Then the helper conversion turns it 11/0 **with the
  refusal in force** — that pairing is the whole point.
- Still-can-fail control: with everything landed, a deliberately degraded
  world (prior-world evidence, no key) still refuses — the restored unit
  tests are that control; show them red once by disabling the refusal check
  locally (then restore it).

### ⛔ Untouchables

- ⛔ **The refusal's SEMANTICS** — re-land them; a green obtained by weakening
  the refusal (or by quietly not re-landing it) is a failed run.
- ⛔ `signing_context!/1`'s bang-brittleness (CX-f4vv) — separate posture
  decision, do not "improve" it in passing. The MatchError presentation is
  ugly; it is also not yours.
- ⛔ `audit_choke_perf_test.exs`, and any budget numbers (CX-5gkw's lane).
- Any other defect: one line, don't pursue.

## 3. ⛔ Acceptance — artifacts

1. **RED FIRST, both populations**: `TrustConfigFailClosedTest`'s 0.4s
   isolated red reproduced in YOUR tree before any change; `MudLiveTest`'s
   10 reds CONSTRUCTED per §2d (green before the refusal re-lands is the
   documented current state, not a discrepancy). Both pasted with rc.
2. **The enumeration** (§2b.1) with per-hit shapes and the denominator stated.
3. **The helper**, with the calls-real-init property visible in its
   implementation, plus its degradation options exercised by at least one
   converting test.
4. **After**: `MudLiveTest` 11/0; `TrustConfigFailClosedTest` green per §2c
   WITH its still-can-fail control shown red once; **CX-k2yr control**: the
   `self-trust was not added` error-line count in a full-suite log drops from
   ~3,500 to ~0 for converted-world tests (grep -c, before AND after — a
   number, not "fewer").
5. **Suites by BLAST RADIUS** — the helper and fixtures touch every app that
   fabricates workspaces: `apps/commonplace/test` (~3283 — a count in the
   HUNDREDS = subtree = VOID), `apps/commonplace_web/test` (134),
   `apps/commonplace_mcp/test` (156), `apps/commonplace_cli/test` (97). Run
   each **separately** (umbrella multi-path silently drops — check counts).
   ⚠️ Main's core-suite failure set is unstable; compare failure SETS at one
   seed against a same-day baseline and quote failure MODES; timeout-mode
   failures among CX-5gkw's four targets are that lane's, not yours — report,
   don't chase.
6. `mix compile --warnings-as-errors` rc=0, direct.
