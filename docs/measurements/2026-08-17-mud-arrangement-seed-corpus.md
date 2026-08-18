# The MUD arrangement defect: a seed corpus, donated by CI

**Date:** 2026-08-17 · **Feeds:** the reproducer at
`2026-08-16-mud-render-ordering-reproducer.md`, whose investigation ended at
"proximate cause found, trigger unexplained" — starved of failing arrangements.

⭐ **CI HAS BEEN DONATING FAILING ARRANGEMENTS THE WHOLE TIME.** CI pins no
seed, so every run rolls a fresh arrangement; the arrangement family fired in
20 of 28 flaky pre-fence reds. Each row below is a (sha, seed) pair whose
arrangement made a MUD-family test fail on the runner.

## ✅ THE CORPUS IS VALIDATED — one row replayed locally

```
row      cb703e81 seed=181261
CI       3389 tests, 2 failures   RoomVisibilityTest
LOCAL    3389 tests, 1 failure    RoomVisibilityTest,
         "(this place has no description)" — the documented symptom
         population identical, seed confirmed by ExUnit's own seed line
```
⇒ **The seeds are a corpus, not a mirage: the defect reproduces at the
harvested (sha, seed) on a different machine.**

⚠️⚠️ **AND THE 1-vs-2 DELTA IS A FINDING, NOT NOISE: SAME sha, SAME seed, SAME
population — DIFFERENT failure count between CI and local.** ⇒ ***A fixed
arrangement reproduces the MECHANISM but not the exact manifestation; machine
state (load, timing) selects WHICH of the family fail within it.*** *This is
the strongest evidence yet that the mechanism has a timing-sensitive
component inside an arrangement-sensitive trigger.*

## How to use a row

```
git worktree add /tmp/wt <sha>
cd /tmp/wt && mix deps.get
mix test apps/commonplace/test --seed <seed>
expect: a MUD-family failure; the EXACT member may differ from CI's (above)
⛔ the verdict line must be PRESENT and the population must MATCH the row's
   era before any conclusion is drawn — a dead run's zero is the same byte.
```

## The rows — 18 runs, harvested 2026-08-17 from pre-fence CI logs

```
run_id       sha       seed    CI failing tests
31468756563  5d7a8e9a  120957  Commonplace.MUD.RoomVisibilityTest
31468824208  fd352dd3  913184  Commonplace.MUD.HumanWebPlayTest
31473711214  d246501b  130234  Commonplace.MUD.RoomVisibilityTest
31508291789  0741fd93  995422  Commonplace.MUD.HumanWebPlayTest
31509505989  d8769fa1  488430  Commonplace.MUD.HumanWebPlayTest+Commonplace.MUD.WebPlayIntegrationTest
31512967177  90ebf27a  284676  Commonplace.MUD.HumanWebPlayTest
31531444048  ffab348d  717010  Commonplace.MUD.HumanWebPlayTest
31533837541  604d1423  800183  Commonplace.MUD.RoomVisibilityTest
31540662948  9c99818a  656827  Commonplace.MUD.HumanWebPlayTest+Commonplace.MUD.RoomVisibilityTest
31543603660  3b36c1c6  812914  Commonplace.MUD.RoomVisibilityTest
31560753178  547d2956  214442  Commonplace.MUD.HumanWebPlayTest
31590205824  cb703e81  181261  Commonplace.MUD.RoomVisibilityTest
31603870229  486b21c3  910450  Commonplace.MUD.RoomVisibilityTest
31604962213  7d4ebd6a  890312  Commonplace.MUD.HumanWebPlayTest
31636476754  e6c6bb8f  497404  Commonplace.MUD.RoomVisibilityTest
31637056307  aa1e37d4  204335  Commonplace.MUD.HumanWebPlayTest
31653172022  1f94c46b  357890  Commonplace.MUD.HumanWebPlayTest
31659178371  e30b0efb  494991  Commonplace.MUD.HumanWebPlayTest
```

## S-loadsep results (2026-08-17/18): load varied at FIXED (sha, seed) — 8 runs

**Design:** row `cb703e81`/181261, 4 quiet + 4 loaded (8 CPU burners, 2×nproc),
interleaved. All 8 runs valid: seed 181261 confirmed from ExUnit's line,
population 3389 every run, verdict lines present. Raw dirs preserved.

| run | arm | failures | identities | symptom occurrences |
|----:|:---:|---------:|---|---:|
| 1,3,5,7 | Q | 1 each | MUD.RoomVisibilityTest (same test, all four) | 1 each |
| 2,8 | L | 1 each | MUD.RoomVisibilityTest (same test) | 1 each |
| 4 | L | 2 | + Process.HotReloadTest | 1 |
| 6 | L | 4 | + Green.BursarTest, Process.HotReloadTest, Presence.CompactorTest | **2** |

**Three findings, in order of strength:**

① ⭐⭐ **THE MUD FAILURE'S IDENTITY IS LOAD-STABLE ON THIS BOX: 8/8 runs, the
same single test** (`RoomVisibilityTest` "owner's own look… (self-read)").
⇒ ⛔ **CPU load does NOT reproduce the CI-vs-local manifestation delta** (CI
saw 2 failures at this same (sha, seed)). The machine-state selector that
differs between CI and this box is NOT plain CPU contention.

② ⭐⭐⭐ **BUT THE MANIFESTATION *SHAPE* MOVED WITH LOAD, ONCE (run 6): SAME
test, SAME assertion (`assert out =~ "Owner's Den"`), DIFFERENT left value:**
```
quiet   "(this place has no description)"
loaded  "Welcome, owner.\n\n(this place has no description)\n(this place has no description)"
```
⇒ **Under load the render pipeline emits a different STRUCTURE — a greeting
plus a DOUBLED room render — at a fixed arrangement.** *The timing component
is inside the render path itself, not only in which test trips.*

③ ⭐ **LOAD KNOCKED OVER THREE ORTHOGONAL TIMING TESTS** — HotReloadTest (runs
4 and 6), BursarTest, CompactorTest — none of which appear in the pre-fence CI
census residue (GhostReaper, AuditChokePerf). ⇒ **The load-sensitive test set
is LARGER than CI's history shows; the census reflects CI's load profile, the
burners a harsher one.** These are S-timing observations under controlled load.

**Small-N honesty:** 4v4 gives direction, not significance. Q arm 4/4
identical; L arm 2/4 with extra failures, 1/4 with the shape change. "Moves
with load" is YES for orthogonal failures and manifestation shape; **NO for
the MUD failure's identity on this box.**

*Reviewer note: one instrument disagreement during verification — the summary
counted symptom OCCURRENCES (run6 = 2), the reviewer's `grep -c` counted LINES
(= 1). The builder was right: both occurrences sit on one line. Count
occurrences, not lines.*
