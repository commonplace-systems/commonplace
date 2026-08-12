# CX-fbah yelixer sync prepare-and-verify evidence

Date: 2026-08-12

Status: **STOPPED at verification step 6; no bundle was created and nothing was published.**

## Why this ran now

The route is perishable. The umbrella object store still retains the unreferenced
standalone history through `dd5988a`, and routine garbage collection can prune
those objects. Prunability, not the prior disposition's licensing, is why this
work pre-empted the next round.

## Immutable inputs

- Audited umbrella tip: `9d121263e69bc14295ce64aa5c7f377956c57f4d`
- Standalone `main`: `f87d43e4079642d5a4c48c10601bce68d9681a4c`
- Standalone `origin/main`: `f87d43e4079642d5a4c48c10601bce68d9681a4c`
- The complete umbrella and standalone ref sets were captured before the run.
  Byte comparison against post-run captures returned exit 0 for both repos.
- The umbrella path corpus was non-empty before splitting: 94 path-changing
  commits and 112 tree entries under `apps/yelixer`.

## Split construction and verification

The work ran only in `/tmp/cx-fbah.sIQKyH`; no branch or ref was created in
either source repository. A normal clone did not initially contain the
unreferenced split point. This was repaired with a local, ref-free fetch:

```text
dd5988a_before_fetch=absent
From /home/jes/yelixer
 * branch dd5988aa1884ead4cb26eb1e6ce501ad905b509f -> FETCH_HEAD
dd5988a_after_precondition=dd5988aa1884ead4cb26eb1e6ce501ad905b509f
```

`git subtree split --prefix=apps/yelixer -b sync/yelixer-umbrella-split`
in the temporary clone produced:

```text
split_tip=7ab2a6fdd2e679422ffd3683fc0bff2c9b154cc0
split_commit_count=113
split_root_count=1
merge_base=dd5988aa1884ead4cb26eb1e6ce501ad905b509f
split_tree=f1e1615a38b18bd2d2406f9d5448b27b2e99fc61
umbrella_subtree_tree=f1e1615a38b18bd2d2406f9d5448b27b2e99fc61
```

`git diff --exit-code <split-tip>^{tree} <umbrella-tip>:apps/yelixer`
returned exit 0. The measured merge base is exactly
`dd5988aa1884ead4cb26eb1e6ce501ad905b509f`. No
`--allow-unrelated-histories` option was used.

## Candidate merge object and graph verification

The temporary standalone clone produced candidate merge commit:

```text
d9f8f3c0537e8d30f74b995fdf77afce97f2b026
```

This is recorded for failure diagnosis only. Because step 6 failed, it is not
an approved handoff object and was not bundled.

Its ordered parents are:

```text
f87d43e4079642d5a4c48c10601bce68d9681a4c 7ab2a6fdd2e679422ffd3683fc0bff2c9b154cc0
```

The index was resolved exactly to the split tree before commit. All of these
standalone-ahead commits passed `git merge-base --is-ancestor <sha> <merge>`:

- `b2a79c6fb6e939cb5cc4f3e7e08e0864472b5a7d`
- `1538962e51d98583331f5b88df013948ffba6f00`
- `b08f767eab5d318aa51cef1752588168fb9bb9d9`
- `7e316f40e7afd6e30eb4f3d323f1f5f346ccb327`
- `9d5775bc514c026b886fd7b70feb873a64fe32c0`
- `f87d43e4079642d5a4c48c10601bce68d9681a4c`

The split tip also passed the ancestor check. Tree equality passed:

```text
git diff --exit-code 7ab2a6fdd2e679422ffd3683fc0bff2c9b154cc0 d9f8f3c0537e8d30f74b995fdf77afce97f2b026
# exit 0
merge_tree=f1e1615a38b18bd2d2406f9d5448b27b2e99fc61
split_tree=f1e1615a38b18bd2d2406f9d5448b27b2e99fc61
```

Placement on standalone `main` is a fast-forward by construction:

```text
first_parent_distance=1
total_reachable_ahead=94
reverse_ahead=0
merge_base_origin_main_result=f87d43e4079642d5a4c48c10601bce68d9681a4c
```

Correction: an initial assertion incorrectly expected total reachable-ahead
count 1. A merge makes all 93 new second-parent commits reachable, so the
total is 94. The correct one-commit placement measure is first-parent distance
1, together with reverse-ahead 0 and the exact merge base above. The corrected
fail-fast assertions passed.

## Test setup and failing acceptance gate

`npm ci --prefix test/fixtures` installed four packages with zero audit
vulnerabilities. Direct import checks succeeded for both `stable` and
`preview`, so neither oracle was missing.

Compilation required writable dependency state. The read-only/shared sources
were copied into `/tmp/cx-fbah.sIQKyH/exact-deps`, and `MIX_DEPS_PATH` plus
`MIX_BUILD_PATH` pointed only at temporary writable paths. No build output was
written to either source repository.

Two setup failures were not treated as green:

1. The first two-package dependency copy failed because `telemetry` was absent.
2. The 50-package umbrella copy exposed that this standalone subtree's
   `mix.lock` has stale `stream_data` metadata and no `telemetry` entry.

To keep the candidate tree unchanged, the standalone-pinned `jason` and
`stream_data` sources plus local `telemetry` were copied and explicitly
compiled. `mix test --no-deps-check` then compiled yelixer, but the suite
stopped before executing tests:

```text
** (Code.LoadError) could not load /tmp/test/support/file_rm_rf_guard.exs. Reason: enoent
    test/test_helper.exs:2: (file)
```

The governing line in the exact split tree is:

```elixir
Code.require_file("../../../test/support/file_rm_rf_guard.exs", __DIR__)
```

In the standalone scratch clone it resolves to
`/tmp/test/support/file_rm_rf_guard.exs`, which does not exist. The error shape
was checked, and the missing target was asserted directly.

The differential corpus positive control found exactly 11 declared tests.
Both oracle packages passed direct import checks. Separate required-oracle
runs then failed with the same `Code.LoadError` before ExUnit emitted a test
summary:

| Oracle | Corpus | Executed | Failures | Invalid | Skipped | Result |
|---|---:|---:|---:|---:|---:|---|
| stable | 11 | 0 | not reported | not reported | not reported | RED before ExUnit count |
| preview | 11 | 0 | not reported | not reported | not reported | RED before ExUnit count |

Therefore the required `11 tests / 0 failures / 0 invalid / 0 skipped` per
oracle was **not** achieved. A missing count is not green.

## Bundle and publication checks

- Bundle path: **none; deliberately not created after step 6 failed**.
- `git bundle verify`: **not run because no partially verified bundle may be
  handed over**.
- Fresh-clone-and-fetch exact-SHA check: **not run because no bundle exists**.
- No push, remote fetch, `ls-remote`, tag, remote branch, force operation, or
  remote mutation was attempted.
- Standalone `main` and `origin/main` remain
  `f87d43e4079642d5a4c48c10601bce68d9681a4c`.
- The standalone ref snapshot is byte-identical before and after the run.
- The umbrella ref snapshot is byte-identical before and after the run;
  umbrella `HEAD` remains `9d121263e69bc14295ce64aa5c7f377956c57f4d`.
- Nothing in the umbrella moved. No dependency flip or yelixer deletion was
  performed. `sol-run.log` was not touched.

## Findings and deviations

- Finding identity (CX-fbah): the exact subtree's `test/test_helper.exs`
  requires an umbrella-only support file by a parent-relative path, so a fresh
  standalone checkout cannot start any ExUnit test.
- Finding identity (CX-fbah): the exact subtree's `mix.exs` declares
  `telemetry`, but its `mix.lock` has no telemetry entry, so an ordinary
  dependency check in a fresh standalone checkout fails before compilation.
- Deviation: the required gated `ticket_create` verb is not exposed in this
  sandbox (`tix` is not installed and no callable ticket tool is available),
  so the two findings could not be filed. The frozen `bd` archive was not used.
  ⇒ **Discharged at review: filed as `CX-1wt1` (test bootstrap, p1) and
  `CX-gqj6` (frozen lockfile, p2) through the gated verb, both re-read
  verified.** Reporting the identities rather than dropping them is what made
  the discharge mechanical.

## Reviewer ruling (2026-08-12)

Both findings independently re-derived from the umbrella, and one of them is
larger than the round could see from inside a scratch clone.

**The two findings share a root cause, and it is the interesting part:**
*being an umbrella app HID the standalone's requirements.* The umbrella
satisfies them from OUTSIDE the app — the root `mix.lock`, the root
`test/support` — so the app's own declarations rotted invisibly, because
nothing in the umbrella ever reads them. `apps/yelixer/mix.lock` was last
touched by `523291ab`, **the subtree import merge itself**, and yelixer is the
only app carrying a lock at all. ⇒ **A subtree split is not only an
extraction; it is the first thing that ever audits an app's
self-containment.**

**On the escaping test bootstrap: it is NOT accidental drift.** All six
umbrella apps use the identical `Code.require_file("../../../test/support/…")`
pattern — a deliberate umbrella-wide rm -rf safety guard. The tension is
genuine: yelixer is simultaneously an umbrella app sharing umbrella test
infrastructure and a standalone library. ⛔ **The fix must not be a
conditional skip** (`File.exists?` → require, else continue): that silently
disables a safety guard in precisely the environment nobody is watching,
converting a loud failure into a quiet loss of protection.

**RULING — CX-fbah is BLOCKED, and the block is recorded in the DAG rather
than in prose:** `CX-fbah` now `needs` `CX-1wt1`. The sync must not proceed
until the extracted tree is self-contained, because the arc's downstream rows
depend on it more than this round did — `CX-b6mz` flips commonplace onto the
external dep, `CX-bx59` wants standalone CI asserting a test count, and
`CX-71m2` DELETES `apps/yelixer`. Publishing a tree whose tests cannot start,
and then deleting the copy that could fix it, is the failure mode this arc has
already come close to once.

**What does NOT change:** the merge mechanism is sound and fully verified.
Split, merge base at `dd5988a`, parent order, six-ancestor check, tree
equality, and fast-forward-by-construction all passed. When `CX-1wt1` lands,
this round re-runs from a fresh split — the candidate merge
`d9f8f3c0537e…` is diagnostic only and must not be resurrected, since it
carries the unfixed tree.

⚠️ **The perishability that justified pre-empting S36 still applies and is now
measured, not theorised:** `dd5988a_before_fetch=absent` in a normal clone.
The route's decay term is real, and the local fetch remains the precondition
each time this is attempted.
- Deviation: the umbrella project root does not define the required
  `mix precommit` task; `mix help precommit` returned
  `The task "precommit" could not be found`. The evidence file is the only
  umbrella worktree change and it passes the final repository integrity checks.
- There was no network/auth failure and no attempt to test that capability
  boundary.
