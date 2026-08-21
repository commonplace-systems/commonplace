# Pinned serve boot — design (the deploys-are-decisions round)

**commonplace (cell-1), drafted 2026-08-21 late.** Plan ranked this near-term
(#14447) after two unannounced serve deploys in one evening (boss #14444);
property spec ratified there, re-affirmed at the #14479/#14482 re-rule. Joint
round: this doc + the serve-side tools are mine; the launcher lane is boss's.

## The defect, observed twice in one night

The serve boots from the SHARED working tree: `cp-serve-launch.sh` starts a
BEAM whose code path is `/home/jes/commonplace/_build/dev`, compiling on boot.
Consequences, both measured 2026-08-21:

1. **Every stop/start is a potential unannounced deploy.** The pass-1/pass-2
   migration restarts booted whatever the tree had advanced to (b1d19ab8 →
   6331ffae-era beams) — two uncertified deploys, executed by the operator
   most careful about exactly this, noticed only by cross-checking beam
   mtimes against serve start.
2. **The deploy-gap monitor is true-and-blind for this class BY
   CONSTRUCTION** (plan #14447, the probe-shares-fate law): an accidental
   deploy *closes* the gap it would report. Its `0` cannot distinguish
   "nothing to deploy" from "everything deployed by accident."
3. (Adjacent, pre-existing) the running serve **lazy-loads from the live
   `_build` forever** (`:interactive` mode — the probe-is-a-write rule), so
   the tree moving under a running serve can mix module vintages at runtime.
   Tonight's instance was proven benign only by a per-module git check.

Every gate built this session — span certification, deploy-gate grep, the
ceremony riders — assumes deploys are DECISIONS. The shared-tree boot makes
them EVENTS.

## The property (ratified, plan #14447)

- **P1** — the serve boots from a **pinned build artifact**, not the live
  working tree.
- **P2** — the pin advances **only by explicit act** (the deploy ceremony).
- **P3** — pin-vs-tree **divergence is observable** by an instrument that
  does not share fate with the thing it measures.

## Mechanism (builder's choice per plan): the deploy worktree

A dedicated git worktree + its own build, owned by the deploy ceremony:

```
/home/jes/commonplace-serve-pin/          # git worktree of the same repo
  ├── (sources at the PINNED sha only)
  ├── _build/dev/                         # compiled HERE, by the ceremony
  └── .pin                                # one line: <sha> <utc-timestamp> <operator>
```

- **Boot**: `cp-serve-launch.sh` cd's into the pin worktree and boots there.
  The serve's code path is the pin's `_build`; the shared tree can churn
  freely — compiles, merges, checkouts — with zero effect on any running or
  future boot. **P1.** A stop/start brackets nothing: restart re-boots the
  same pinned beams. Lazy loads (hazard 3) now pull pinned-vintage modules —
  the runtime-mix hazard collapses to same-vintage.
  - The pin path is a **CONSTANT in the launcher, never an env var** (boss
    #14484, ruled): the launcher's `env -i` allowlist exists to eliminate
    launch-environment facts, and "which tree the serve boots from" is
    precisely the class of fact it must not reintroduce (the LETTA lesson,
    third recurrence). The launcher never needs the SHA — the pin is a
    property of the worktree, written by `cp-deploy-pin`; the launcher's
    whole job is "boot from THIS directory, whatever it points at."
  - ⛔ **The launcher REFUSES to boot — loudly, no serve — if the pin
    worktree is missing, is not a git worktree, or has no `_build`. It
    NEVER falls back to the shared tree.** A silent fallback is tonight's
    accident in reverse, scheduled for the day someone deletes the worktree
    — i.e. when nobody is watching. Fail loud, refuse to serve.
- **Deploy** (`bin/cp-deploy-pin <sha>`): fetch → verify the sha exists on
  origin/main → **disk-floor gate** (refuse below a free-space threshold —
  tonight's 17G blow-up was found by a backup dying mid-write because no
  ceremony carried a headroom check; the check lives with the act, not in
  the operator's attention — boss #14484) → `git -C <pin> checkout <sha>` →
  `mix compile` in the pin → write `.pin` → print the receipt. Advancing
  the pin IS the deploy ceremony step; nothing else writes to the worktree.
  **P2.**
- **Observe** (`bin/cp-pin-status`): prints, side by side, with no shared
  inputs: the `.pin` sha · the pin worktree's actual `git rev-parse HEAD`
  (they must agree — a disagreement is a tampered/half-advanced pin) · the
  running serve's boot identity (existing `cp-verify-deploy` resident-digest
  against the PIN's beams) · `origin/main` HEAD. Output states the lag in
  commits ("pin is N commits behind main"), which is a REAL number that
  accumulates until a ceremony clears it — the gauge and the deploy no
  longer share fate. **P3.**

### Why not the alternatives

- **`mix release` (embedded mode)** — the deeper fix: kills lazy-loading
  entirely, fully self-contained. Rejected FOR THIS ROUND as a larger blast
  radius (release config, runtime env handling, escript/BEAM-distribution
  interplay with hermes-safe procedures, every deploy memory rewritten).
  Named as the hardening follow-up the worktree pin does not foreclose —
  the ceremony and gauge carry over unchanged if the artifact later becomes
  a release.
- **`MIX_BUILD_PATH` pin without a source pin** — rejected: a boot that
  compiles from moved source into a pinned build path just relocates the
  accident.

## Ceremony deltas

- Deploy ceremony gains ONE step and loses none: `cp-deploy-pin <certified
  sha>` replaces "the restart picks up whatever compiled." Certification
  stays upstream of it, exactly as tonight.
- §3 migrations, probes, test runs, Sol lanes: unaffected — they never
  touch the pin worktree.
- `cp-deploy-gap` keeps its job INSIDE the pin (beams newer than boot in
  the pin worktree = a real anomaly again, since nothing legitimate compiles
  there between ceremonies).
- Launcher lane (boss's): `cp-serve-launch.sh` boots from the pin dir; env
  capture/diff discipline unchanged; hermes-safe stop/start unchanged.

## Acceptance (red-first, all demonstrable without touching the live serve)

1. **P2/P3 red arm**: advance the SHARED tree past the pin → `cp-pin-status`
   reports the lag (nonzero, named shas); the pin worktree's beams unchanged
   (mtime + digest). The gauge is seen to go red on real divergence.
2. **P1 arm**: boot a throwaway serve from a pin at sha X, then merge/compile
   sha Y in the shared tree, restart the throwaway from the pin → it boots X
   again, verified by resident digest. The accident of 2026-08-21 is
   structurally impossible, demonstrated.
3. **Half-advanced pin refusal**: `.pin` says sha A, worktree HEAD is sha B →
   `cp-pin-status` refuses loudly (a tampered or interrupted advance is not
   a valid pin), and `cp-serve-launch.sh` refuses to boot from it.
4. **Ceremony green arm**: `cp-deploy-pin <sha>` → status reads clean, lag 0
   against the deployed sha, launch boots it, `cp-verify-deploy` zero-skew
   against the PIN's beams.

## The joint half — RESOLVED (boss #14484, all three)

- **(a) Pin path**: constant in the launcher (folded into Boot above), with
  the refuse-never-fallback clause.
- **(b) Disk**: signed off — 16G free, current `_build` measured 197M (my
  1-2G estimate was conservative). Disk-floor gate folded into
  `cp-deploy-pin` above.
- **(c) First-pin migration** of serve 1437472: a NORMAL deploy ceremony,
  no special case — "a one-time special migration is how the ceremony's
  guarantees get skipped exactly once."

## Acceptance addendum (from the (a) resolution)

5. **Refusal arm**: pin worktree absent / not-a-worktree / no `_build` →
   the launcher refuses loudly and starts NOTHING; specifically it must be
   demonstrated that no fallback boot from the shared tree occurs.

## Scope fence

- NOT `mix release`/embedded mode (named follow-up).
- NOT the MCP escript's freshness lane (separate artifact, own tooling,
  rebuilt+verified 361/361 tonight).
- NOT any change to certification itself — this round makes certification's
  ASSUMPTION (deploys are decisions) true, not its content.
