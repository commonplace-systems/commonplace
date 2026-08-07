# State-projection tooling build report

Built 2026-08-07 from `.stateproj/BRIEF.md`, fixtures only. No production
render was performed. No serve, distribution, network, live store, or
`.sizing/` access was used. The coordinator's review remains the first real
render.

## Delivered behavior

- `bin/state-render` has a production serve-read path matching the
  `bin/tix-migrate` flock / `ERL_INETRC` / unique short-name probe /
  `mix run --no-start` pattern. That branch was not executed. Its explicit
  `--fixture` path generated all proof artifacts. It atomically replaces
  `STATE.md`, `.commonplace-state/tix-export.jsonl`, and only the literal
  marked block in `CLAUDE.md`. Missing or duplicate markers fail before any
  output replacement.
- Trust is derived from the prior woven render time as
  `rendered_at + clamp(3 * observed_gap, 45m, 6h)`. Bootstrap uses 45m. The
  cap-boundary comment is beside `TRUST_CAP_SECONDS`: no-coordination holds
  only below the two-hour observed interval (`cap / multiplier`). Every run
  prints the observed gap and derived window.
- `bin/tix-truth-scan` is offline. It reads only local git history and the
  stamped JSONL export, reports both input ages, scans both directions with
  denominators and named shapes, writes one atomic verdict line, and exits
  0/1/2 for clean/findings/could-not-scan.
- `bin/state-prime` compares the woven timestamps with its invocation-time
  local clock. Fresh content is emitted; stale content is withheld behind a
  loud banner; missing and malformed state emit a loud stdout alarm.
- `CLAUDE.md` contains the required literal marker pair near the top of the
  project overview. The initial pointer deliberately says no render has run.
- Ongoing ownership remains boss-owned Box cron every 15 minutes, running
  `bin/state-render` and then `bin/tix-truth-scan`. No cron or hook was
  installed or distributed in this fixture-only build.

## Operator hook wiring

Exact production invocation:

```text
bin/state-prime
```

Exit-code taxonomy:

- `0` — either a fresh state block or a stale safety banner was emitted to
  stdout.
- `1` — bad invocation (unknown arguments or an invalid test-only `--now`).
- `2` — `STATE.md` was missing or its woven timestamp line was unparseable;
  the loud alarm was still emitted to stdout. Silence is never valid.

The `--state` and `--now` switches are fixture/red-proof controls only. The
operator hook must use the exact zero-argument invocation above.

## Final red-proof transcript (verbatim)

Command: `.stateproj/test_state_projection.sh` (exit 0).

```text
RED-PROOF 1A — backdated STATE.md
!!! STATE PROJECTION IS STALE !!!
Rendered 2h 0m ago; trust expired 1h 15m ago.
DO NOT SCOPE FROM THIS STATE.md.
Stale frontier content has been withheld.
Fallback: bin/state-render, or tix via serve erpc, or git log --oneline --since=<week>.

RED-PROOF 1B — deleted STATE.md
!!! STATE PROJECTION UNAVAILABLE !!!
STATE.md is missing at /home/jes/sol-perf/wt/tmp/state-projection.H8AlYd/prime/deleted-STATE.md.
DO NOT SCOPE WORK WITHOUT CURRENT STATE.
Fallback: bin/state-render, or tix via serve erpc, or git log --oneline --since=<week>.
exit=2

RED-PROOF 1C — fresh STATE.md
# Project state

## FRONTIER

> RENDERED 2026-08-07T00:00Z — TRUST UNTIL 2026-08-07T00:45Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

Ready: **2** · Blocked: **1**
- `CX-flight` [p0] Wire fixture render — claimed_by: agent-fixture
- `CX-open` [p1] Build projection reader — claimed_by: unclaimed
- `CX-blocked` [p2] Await coordinator hook — claimed_by: unclaimed

## IN-FLIGHT

> RENDERED 2026-08-07T00:00Z — TRUST UNTIL 2026-08-07T00:45Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- `CX-flight` Wire fixture render — status: in_progress · holder: agent-fixture

## RECENT CLOSES

> RENDERED 2026-08-07T00:00Z — TRUST UNTIL 2026-08-07T00:45Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- `CX-closed-evidence` 2026-08-06T22:00:00Z — Fix renderer atomicity — **WHAT-THE-FIX-WAS:** Replaced direct writes with same-directory temporary files and rename.
- `CX-closed-no-evidence` 2026-08-06T21:00:00Z — Update undocumented close — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**

## OPEN-WITH-BLOCKER

> RENDERED 2026-08-07T00:00Z — TRUST UNTIL 2026-08-07T00:45Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- `CX-blocked` Await coordinator hook — Blocked by coordinator hook ownership.

## TRACKER-TRUST

> RENDERED 2026-08-07T00:00Z — TRUST UNTIL 2026-08-07T00:45Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

scanner has not run

RED-PROOF 2A — planted both-directions discrepancies
tix truth scan
==============
git input: local HEAD 31a0f0b at 2026-08-07T02:30Z (age 0h 30m; local history is the fresh source)
tix input: /home/jes/sol-perf/wt/tmp/state-projection.H8AlYd/prime/.commonplace-state/tix-export.jsonl as_of 2026-08-07T00:00Z (age 3h 0m)

SHIPPED-BUT-OPEN: 1/3 open tickets
  CX-open  status=open  title=Build projection reader

CLOSED-BUT-UNREFERENCED SHAPES: 1/2 closed tickets
  Review shapes, not alarms: legitimate non-code closes are common.
  CX-closed-no-evidence  status=closed  title=Update undocumented close

VERDICT: DISCREPANCIES — 1/3 shipped-but-OPEN; 1/2 closed-but-unreferenced SHAPES; scanned 2026-08-07T03:00Z; export as_of 2026-08-07T00:00Z (age 3h 0m)
exit=1

RED-PROOF 2B — clean both-directions fixture
tix truth scan
==============
git input: local HEAD 31a0f0b at 2026-08-07T02:30Z (age 0h 30m; local history is the fresh source)
tix input: /home/jes/sol-perf/wt/.stateproj/fixtures/scan-clean.jsonl as_of 2026-08-07T03:00Z (age 0h 0m)

SHIPPED-BUT-OPEN: 0/1 open tickets

CLOSED-BUT-UNREFERENCED SHAPES: 0/1 closed tickets
  Review shapes, not alarms: legitimate non-code closes are common.

VERDICT: CLEAN — 0/1 shipped-but-OPEN; 0/1 closed-but-unreferenced SHAPES; scanned 2026-08-07T03:00Z; export as_of 2026-08-07T03:00Z (age 0h 0m)
exit=0

RED-PROOF 3 — generator idempotency and marker fencing
PASS: STATE.md byte-identical after timestamp normalization
PASS: CLAUDE.md bytes outside markers untouched

RED-PROOF 4 — close without evidence placeholder
- `CX-closed-no-evidence` 2026-08-06T21:00:00Z — Update undocumented close — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**

RED-PROOF 5A — widened gap reaches 6h cap and remains fresh
state-render: observed gap: 10800s (180.0m); derived trust window: 21600s (360.0m); trust until 2026-08-07T09:00Z
state-render: wrote /home/jes/sol-perf/wt/tmp/state-projection.H8AlYd/clamps/STATE.md, /home/jes/sol-perf/wt/tmp/state-projection.H8AlYd/clamps/.commonplace-state/tix-export.jsonl, and CLAUDE.md marker block atomically
# Project state

## FRONTIER


RED-PROOF 5B — narrow gap stays at 45m floor
state-render: observed gap: 300s (5.0m); derived trust window: 2700s (45.0m); trust until 2026-08-07T03:50Z
state-render: wrote /home/jes/sol-perf/wt/tmp/state-projection.H8AlYd/clamps/STATE.md, /home/jes/sol-perf/wt/tmp/state-projection.H8AlYd/clamps/.commonplace-state/tix-export.jsonl, and CLAUDE.md marker block atomically

RED-PROOF 6 — no direct-store shape in delivered scripts
PASS: 0 matches for CubDB or direct store-open shapes across all three scripts

ALL RED-PROOFS PASSED
```

## Other verification

- `bash -n bin/state-render` — exit 0.
- `bash -n .stateproj/test_state_projection.sh` — exit 0.
- Python compile checks for `bin/state-prime` and `bin/tix-truth-scan` —
  exit 0 without writing bytecode.
- `git diff --check` — exit 0.
- `MIX_ENV=test ... Mix.Task.run("compile", ["--warnings-as-errors"])`
  using the process-local `Mix.PubSub` shim — exit 0. It compiled/generated
  `phoenix_live_view`, `yelixer`, `commonplace`, `commonplace_cli`,
  `commonplace_bots`, `commonplace_mcp`, and `commonplace_web` cleanly.

## Anomalies, unsmoothed

- The first planted scanner run exposed that the initial ID regex stopped at
  a second hyphen. It falsely shaped `CX-closed-evidence`; the regex was
  widened, then the planted proof reported exactly the intended one open hit
  and one closed shape.
- The next clean scan correctly stayed red because the first clean fixture
  omitted its closed ticket's commit reference. The fixture commit was fixed;
  the final clean proof is 0/1 in both directions and exits 0.
- `bd ready --json` could not start its Dolt server: this sandbox forbids its
  local TCP listener (`socket: operation not permitted`). No tracker state was
  read or changed.
- A plain `mix help precommit` could not start Mix.PubSub because the sandbox
  rejects its TCP socket. With the process-local no-op `Mix.PubSub` shim, Mix
  reported that no `precommit` task exists in this repository.
- The first shimmed dev `mix compile --warnings-as-errors` found an existing
  partial dependency build: `phoenix_live_reload` could not read
  `_build/dev/lib/phoenix/priv/static/phoenix.js`. The test-environment compile
  then completed cleanly with warnings-as-errors. No dependency clean/update
  or network operation was attempted.
- `.g486/` and `.sizing/` were pre-existing untracked directories. They were
  not modified; `.sizing/` was never opened or used. Root `STATE.md` and
  `.commonplace-state/` were intentionally not generated, preserving the
  coordinator's first-real-render boundary.
- Per the dispatch note, no commit was attempted: this sandbox's worktree git
  metadata resolves outside its writable mount. All delivered changes remain
  unstaged. Nothing was pushed or distributed.

## File inventory

Delivered/changed, all unstaged:

- `CLAUDE.md`
- `bin/state-render`
- `bin/tix-truth-scan`
- `bin/state-prime`
- `.stateproj/fixtures/render-input.jsonl`
- `.stateproj/fixtures/scan-clean.jsonl`
- `.stateproj/test_state_projection.sh`
- `.stateproj/REPORT.md`

Input read but unchanged:

- `.stateproj/BRIEF.md`
