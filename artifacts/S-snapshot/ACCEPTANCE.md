# S-snapshot measurement result

## Outcome

REPRODUCED, with a partially matching shape.

- Stage: A, test A, line 71 invocation
- Repetition: 4 (four observable seed/verdict blocks; repeat-until-failure stopped here)
- Seed: 1745
- Test: `snapshot command writes a snapshot commit for the resolved doc`
- Full invocation log: `artifacts/S-snapshot/stageA-test-A-line71.log`
- Verbatim ExUnit failure body: `artifacts/S-snapshot/stageA-test-A-rep04-failure-body.log`

The reproduced failure matches the captured CI body's core failure:

```text
** (MatchError) no match of right hand side value: {:error, :enoent}
    (cubdb 2.0.2) lib/cubdb.ex:1499: CubDB.trigger_compaction/1
    (cubdb 2.0.2) lib/cubdb.ex:1523: CubDB.do_compact/1
    (cubdb 2.0.2) lib/cubdb.ex:1358: CubDB.handle_call/3
```

It differs in where the CubDB compaction crash surfaced. The CI body failed from the test body:

```text
code: Commonplace.CLI.Snapshot.do_run(dir, "", ["notes.txt"])
(commonplace 0.1.0) lib/commonplace/store/commit_store.ex:674: Commonplace.Store.CommitStore.snapshot/2
```

The reproduced body instead failed during setup's initial commit creation:

```text
test/commonplace/cli/snapshot_test.exs:41: Commonplace.CLI.SnapshotTest.__ex_unit_setup_0/1
test/commonplace/cli/snapshot_test.exs:1: Commonplace.CLI.SnapshotTest.__ex_unit__/2
```

Classification: PARTIALLY MATCHING. The store, `GenServer.call(... {:create_commit, ...})`, CubDB `{:error, :enoent}`, compaction function, and CubDB line sequence match; the operation phase and caller stack do not.

## Stage 0 baseline

- Dependency check: dependencies initially absent.
- `mix deps.get`: package sources downloaded, then command exited nonzero because Hex could not persist `/home/jes/.hex/cache.ets` in the read-only sandbox (`{:error, :eaccess}`). Log: `stage0-deps-get.log`.
- `mix compile --warnings-as-errors`: passed on rerun after package download. Wall time 65.79s. Log: `stage0-compile-rerun.log`.
- File-alone test seed: 183193.
- Verdict: `3 tests, 0 failures`.
- ExUnit time: 0.1s; cold test-environment wall time: 88.03s.
- Uptime before: 2026-08-18T05:44:48Z; up 143 days, 7:31; load average 3.18, 4.19, 4.51.
- Uptime after: 2026-08-18T05:48:08Z; up 143 days, 7:34; load average 5.82, 5.09, 4.81.

## Stage A

- Uptime before: 2026-08-18T05:48:25Z; up 143 days, 7:35; load average 5.00, 4.96, 4.77.
- Uptime after: 2026-08-18T05:49:09Z; up 143 days, 7:35; load average 4.55, 4.85, 4.74.
- Test A (line 71): 4 runs observed, failure on run 4 at seed 1745. Seeds: 736192, 980870, 991755, 1745.
- Test B (line 86): 201 runs observed, zero failures. All seeds are retained in `stageA-test-B-line86.log` and `stageA-test-B-seeds.log`.
- Test C (line 106): 201 runs observed, zero failures. All seeds are retained in `stageA-test-C-line106.log` and `stageA-test-C-seeds.log`.
- Seed holding answer: NOT HELD FIXED. Every run printed a seed line and the seed values changed within each invocation. The red therefore did not occur under a fixed seed; the brief's fixed-seed discriminator does not apply.

## Stage B

- Actual runs: 30 of 30, within the 45-minute bound.
- Population: 121 tests per run, matching the brief's cited CI population.
- Result: 30 runs with zero failures; every run had a verdict line and exit status 0.
- Seeds: 167141, 481953, 232375, 781808, 220839, 32477, 125022, 309011, 564663, 910784, 943515, 595427, 189449, 257804, 236414, 865882, 739067, 210497, 380378, 665257, 749892, 934011, 174476, 992297, 588692, 631348, 811373, 268024, 519071, 690025.
- Uptime before: 2026-08-18T05:49:27Z; up 143 days, 7:36; load average 3.84, 4.67, 4.68.
- Uptime after: 2026-08-18T05:53:29Z; up 143 days, 7:40; load average 4.35, 4.77, 4.75.
- Near-miss: none. No missing verdict, nonzero exit, boot failure, or PORT 4002 collision was observed.

Across all recorded stage-boundary snapshots, the 1/5/15-minute load-average ranges were 3.18-5.82 / 4.19-5.09 / 4.51-4.81.

## Brief discrepancies and environment qualifications

1. The literal prescribed command `--repeat-until-failure 200` produced 201 observable run blocks for each green invocation (an initial run plus 200 repeats), not 200. The commands were executed exactly as written; actual counts are reported above.
2. The captured CI failure occurred inside `Snapshot.do_run/3`; this reproduction occurred in test setup at line 41. It is not the identical full body.
3. `mix deps.get` could not persist Hex's home-cache file because `/home/jes/.hex` is read-only in the sandbox, although downloads into the worktree completed and compilation subsequently passed. This is sandbox-shaped.
4. Repository instructions claim `bd` is the issue tracker, but the local `bd` command refused because it is a frozen archive and directed users to a live MCP path. The brief says no CX ticket exists and mandates only `S-snapshot`; no other ID was created or used.
5. The generic repository completion workflow requires commit and push, while this round's specific brief says `.git` is read-only, never commit, and leave work unstaged. The round-specific rule was followed.

No fix, assertion change, setup/teardown change, sleep, skip, live-store contact, or serve contact was performed.
