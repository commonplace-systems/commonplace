# S-snapshot execution report

## Phase 1 — red first

- Initial command attempt did not execute tests because dependencies were absent; `red-first.log` records the Mix dependency error.
- `mix deps.get` fetched dependencies and then hit the brief's anticipated Hex cache `:eacces`; compilation subsequently passed.
- The actual red-first invocation failed at repetition 7 after six greens.
- Verdict: `3 tests, 1 failure, 2 excluded`.
- Shape: `{:error, :enoent}` from `CubDB.trigger_compaction/1` at `cubdb.ex:1499` during snapshot setup.

## Phase 2 — ruled fix

- Both `Application.get_env(:commonplace, :data_dir, "data")` captures in `application.ex` are expanded with inline `sol/s-snapshot-fresh-s3` mechanism comments.
- `CommitStore.init/1` expands the fetched `data_dir` before join, lock, or CubDB use, with the same inline mechanism citation.
- `mix compile --warnings-as-errors` passed before and after the change.
- Only the two changed source files were passed to `mix format`. The current formatter also reflowed one pre-existing `DeployGapMonitor` expression in the touched application file; restoring it makes `--check-formatted` fail, so the final diff retains that mechanical hunk.

## Pre-declared selector sweep

The selector returns 19 executable captures plus one doc mention, not the brief's claimed 8 executable sites.

| Site(s) | Classification | Read evidence |
| --- | --- | --- |
| `application.ex:75` | Covered by Door 1 and Door 2 for CommitStore; also feeds independent boot consumers | Passed to Store.Supervisor, SecretStore, workspace locking, and node-name handling. |
| `application.ex:306` | Covered directly by Door 1; independent of CommitStore | Immediately joins `trust.json` for a filesystem probe. |
| `sync/export.ex:124`, `sync/watcher.ex:696`, `sync/agent.ex:808`, `sync/dir_agent.ex:457`, `sync/entry_agent.ex:368` | Residual independent captures; report-only | Feed `ArtifactStore.new/1`; that struct retains the raw directory and later joins `artifacts/...` for filesystem operations. |
| `git_bridge/server.ex:451` | Residual independent capture; report-only | Passed to RootWritePolicy, which joins and reads `<data_dir>/root`. |
| `trust.ex:1263` | Residual independent capture; report-only | Reads `trust.json` and local node identity artifacts by joined paths. |
| `crypto/node_identity.ex:53,84,114` | Residual independent captures; report-only | Read/create node identity, signing-key, and public-key artifacts under the supplied directory. |
| `workspace.ex:159,194` | Residual independent captures; report-only | Read `<data_dir>/root` and read/create `<data_dir>/node_id`; line 150 is only a doc mention. |
| `document/view_transclusion.ex:276` | Residual independent capture; report-only | Joins and reads `<data_dir>/root`. |
| `process/orchestrator.ex:151,790,795,827` | Residual independent captures; report-only | Sweep/read/write/remove orchestrator status and pid files by joined paths. |

No read showed intentional dependence on resolving the same relative string under a later cwd. Each use addresses the workspace selected at capture/call time, so expansion preserves that meaning.

## Phase 3 — two post-fix arms

- Harness reset: the pre-fix run left root `tmp/test_data` with commits and boot artifacts, plus app-directory `tmp/test_data` with `commits.lock` and `node_id` but no `commits/`. The sandbox rejected recursive deletion, so both exact trees were moved to recoverable `/tmp/S-snapshot-reset`; both candidate paths were absent before Arm A.
- Arm A invocation 1: 201 occurrences of `3 tests, 0 failures, 2 excluded`; no failure verdict.
- Arm A invocation 2: 201 occurrences of `3 tests, 0 failures, 2 excluded`; no failure verdict.
- Arm B literal class verdict after each invocation: **FAIL** — two `tmp/test_data` trees exist. `snapshot_test.exs:31` unconditionally runs `File.mkdir_p!("tmp/test_data")` after Mix changes cwd, making the brief's literal one-tree assertion impossible on this HEAD.
- Arm B commits-store verdict after each invocation: **PASS** — exactly one `commits/` directory exists, at root `tmp/test_data/commits`; `apps/commonplace_cli/tmp/test_data/commits` never appears. The app tree contains only `node_id` after the fixed runs.

## Phase 4 — blast radius

- `mix test apps/commonplace/test`: **NO VERDICT / TIMEOUT** at the declared 30-minute budget. Before termination it emitted 109 numbered failures, and all 109 captured failure bodies assert that CubDB's now-absolute path equals the old relative `tmp/test_data/commits` string. No final population line was emitted, so the brief's claimed 3582 population cannot be confirmed from this run.
- `mix test apps/commonplace_cli/test`: **PASS — 121 tests, 0 failures**.

The root umbrella has no `precommit` alias. The only discovered alias is app-local in `apps/commonplace_web/mix.exs` and wraps compile, unused-dependency unlock, tree formatting, and that app's tests; it is not a valid root replacement for the two ruled blast-radius commands.

## Discrepancies and near-misses

1. Dependencies were absent, so the first Phase 1 command attempt could not execute tests; the fresh red window remained open and the actual invocation reproduced at repetition 7.
2. The sweep count is 19 executable sites plus one doc mention, not 8.
3. The pre-fix app tree existed without `commits/`; the brief discusses only the commits-directory flip.
4. The literal one-`tmp/test_data` class arm is contradicted by the test's own unconditional relative `File.mkdir_p!/1`. The narrower and mechanism-relevant one-`commits/` assertion passes twice.
5. The core blast suite is not green: old test assertions explicitly require CubDB to retain a relative data-dir string. Updating those expectations was outside the ruled two-door/report-only scope, so no test semantics were improvised.
6. The core suite stalled without a verdict past its usual duration and was bounded at 30 minutes.
7. Formatting the touched application file necessarily adds one unrelated, behavior-neutral reflow; removing it fails the formatter check.
