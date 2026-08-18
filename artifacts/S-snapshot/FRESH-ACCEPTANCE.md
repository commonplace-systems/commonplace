# S-snapshot fresh-worktree measurement

## Outcome

CONFIRMED against the brief's pre-declared table.

- The fresh-worktree precondition held: the first prescribed `ls tmp apps/commonplace_cli/tmp` returned `No such file or directory` for both locations.
- A low-count red occurred in invocation 1, repetition 7.
- The app-dir CubDB path `apps/commonplace_cli/tmp/test_data/commits` was absent in every probe through invocation 3, including invocation 3's failing repetition, and existed in the required post-invocation read after invocation 3.
- In both invocations after that flip, reds ceased: invocations 4 and 5 each completed 201 observable repetitions with zero failures.

Actual budget: all 5 serial invocations, well inside the 60-minute total bound. There were 411 observable repetitions: 7 + 1 + 1 + 201 + 201. Three repetitions were red.

## Precondition and compilation

The step-0 command produced:

```text
ls: cannot access 'tmp': No such file or directory
ls: cannot access 'apps/commonplace_cli/tmp': No such file or directory
```

No test, suite, warm-up, or store manipulation preceded that read.

The first pre-instrumentation compile did not reach compilation because dependencies were absent. [`fresh-s3-pre-instrument-compile.log`](fresh-s3-pre-instrument-compile.log) records exit 1 and Mix's instruction to run `mix deps.get`. The allowed `mix deps.get` downloaded the dependencies, then exited 1 at the known read-only Hex cache boundary (`/home/jes/.hex/cache.ets`, `{:error, :eaccess}`); see [`fresh-s3-deps-get.log`](fresh-s3-deps-get.log). The rerun compile passed with exit 0 in [`fresh-s3-pre-instrument-compile-rerun.log`](fresh-s3-pre-instrument-compile-rerun.log).

The test file was copied to `/tmp/S-snapshot-snapshot_test.exs.backup`, the round-2 diff was applied verbatim, and the target test moved from line 71 to line 114 because the diff adds 43 lines. The instrumented compile passed with exit 0 in [`fresh-s3-instrumented-compile.log`](fresh-s3-instrumented-compile.log).

## Invocation results and store reads

| Invocation | Repetitions | Result | App-dir probe at the red/first rep | Post-run app-dir CubDB path |
| --- | ---: | --- | --- | --- |
| 1 | 7 | red at rep 7, seed 689518 | configured dir existed with `node_id`; `tmp/test_data/commits` absent | absent |
| 2 | 1 | red at rep 1, seed 410997 | configured dir had `node_id`, `commits.lock`; CubDB path absent | absent |
| 3 | 1 | red at rep 1, seed 808046 | configured dir had `node_id`, `commits.lock`; CubDB path absent | present with `0.cub` |
| 4 | 201 | green | configured dir and CubDB path present | present |
| 5 | 201 | green | configured dir and CubDB path present | present |

The complete per-repetition `CX_SNAPMECH` lines and verdicts are in the invocation logs:

- [`fresh-s3-invocation-01.log`](fresh-s3-invocation-01.log): 7 probes and 7 verdicts; one red.
- [`fresh-s3-invocation-02.log`](fresh-s3-invocation-02.log): 1 probe and 1 red verdict.
- [`fresh-s3-invocation-03.log`](fresh-s3-invocation-03.log): 1 probe and 1 red verdict.
- [`fresh-s3-invocation-04.log`](fresh-s3-invocation-04.log): 201 probes and 201 green verdicts.
- [`fresh-s3-invocation-05.log`](fresh-s3-invocation-05.log): 201 probes and 201 green verdicts.

Within invocation 1, CommitStore pid `#PID<0.8532.0>` and CubDB pid `#PID<0.8535.0>` were stable across all seven probes. Invocations 2-5 each used stable in-invocation pids `#PID<0.279.0>` and `#PID<0.282.0>`. Reused numeric pid representations across new BEAMs are not cross-invocation identity.

The post-run filesystem records are [`fresh-s3-after-invocation-01.log`](fresh-s3-after-invocation-01.log), [`fresh-s3-after-invocation-02.log`](fresh-s3-after-invocation-02.log), [`fresh-s3-after-invocation-03.log`](fresh-s3-after-invocation-03.log), [`fresh-s3-after-invocation-04.log`](fresh-s3-after-invocation-04.log), and [`fresh-s3-after-invocation-05.log`](fresh-s3-after-invocation-05.log).

After every invocation, the worktree-root store held all three boot artifacts:

```text
tmp/test_data/node_id
tmp/test_data/node_signing_key
tmp/test_data/node_signing_public_keys.json
```

The app-dir store held only `apps/commonplace_cli/tmp/test_data/node_id`; it never held either signing artifact. Therefore boot-time cwd was the worktree root, while every test-time probe reported cwd `/home/jes/sol-snapshot-fresh/wt/apps/commonplace_cli`.

## Red bodies and round-1 comparison

Every red has its full verbatim ExUnit body, preceding GenServer termination records, repetition seed, and verdict in its invocation log:

- invocation 1 / repetition 7: [`fresh-s3-invocation-01.log`](fresh-s3-invocation-01.log)
- invocation 2 / repetition 1: [`fresh-s3-invocation-02.log`](fresh-s3-invocation-02.log)
- invocation 3 / repetition 1: [`fresh-s3-invocation-03.log`](fresh-s3-invocation-03.log)

Classification against round 1's captured body: PARTIALLY MATCHING for all three reds. All three reproduce the same inner failure and line sequence:

```text
** (MatchError) no match of right hand side value: {:error, :enoent}
    (cubdb 2.0.2) lib/cubdb.ex:1499: CubDB.trigger_compaction/1
    (cubdb 2.0.2) lib/cubdb.ex:1523: CubDB.do_compact/1
    (cubdb 2.0.2) lib/cubdb.ex:1358: CubDB.handle_call/3
```

They also surface in the same outer phase as round 1, the test setup's `GenServer.call(Commonplace.Store.CommitStore, {:create_commit, ...}, 5000)`. The instrumentation shifts the static source locations by 43 lines. The differing static lines are:

```text
round 1: apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs:71
fresh s3: apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs:114

round 1: test/commonplace/cli/snapshot_test.exs:41: Commonplace.CLI.SnapshotTest.__ex_unit_setup_0/1
fresh s3: test/commonplace/cli/snapshot_test.exs:84: Commonplace.CLI.SnapshotTest.__ex_unit_setup_0/1
```

Seeds, pids, UUIDs, transaction payloads, and B-tree state also differ per execution. Thus the full bodies are not byte-identical, while the failure mechanism, CubDB stack, store call, and setup phase match. As in round 1, these remain only partially matching the older CI sample because CI surfaced from `Snapshot.do_run/3`, not setup.

## Discrepancies and near-misses

1. The broad app-dir configured directory appeared during invocation 1, but the narrower CubDB `commits` child did not. Reds continued in invocations 2 and 3. The cessation tracks the child path named by `%CubDB.State{}.data_dir`, which flipped only across invocation 3. Treating the broad directory's earlier appearance as the table's flip would incorrectly yield THIRD; the table specifically says the app-dir commits path.
2. `--repeat-until-failure 200` again yielded 201 observable repetitions in each bounded-green invocation, not 200: the initial run plus 200 repeats.
3. The first exact test invocation compiled the cold test environment before executing the repetitions. This was part of the prescribed invocation, not an extra early run.
4. `mix deps.get` exited nonzero after downloading packages because Hex could not persist its host cache. The required compile subsequently passed, so this matches the brief's stated non-fatal qualification.
5. The app-dir `commits/` flip was bracketed by the invocation-3 pre-repetition probe (absent) and the mandatory post-invocation filesystem read (present). There was no later probe inside that invocation because its first repetition was red.

No fix, product-code change, assertion change, setup/teardown repair, store deletion/creation by hand, live-store contact, serve contact, or other provocation was performed.

## Restoration

The instrumented test was restored with `cp` from the backup. `cmp` returned 0, and `git diff -- apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs` was empty.
