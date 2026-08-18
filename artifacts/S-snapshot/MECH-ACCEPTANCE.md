# S-snapshot mechanism measurement

## Outcome

THIRD-THING (bounded null), against the brief's labeled captured-stale-path hypothesis.

The prescribed test did not go red in three serial invocations. Each invocation produced 201 observable repetitions (the initial run plus 200 repeats), for 603 green repetitions total. No provocation was performed.

At every probe:

- cwd was `/home/jes/sol-snapshot-repro/wt/apps/commonplace_cli`
- application `data_dir` was `tmp/test_data`, and it existed
- CubDB `%CubDB.State{}.data_dir` was `tmp/test_data/commits`, and it existed
- the configured path and CubDB path both had successful `File.ls/1` reads
- CommitStore pid was stable within each invocation at `#PID<0.279.0>`
- CubDB pid was stable within each invocation at `#PID<0.282.0>`

The equal printed pid numbers between invocations do not prove cross-invocation process identity: each invocation starts a new BEAM, and the allocator reused the same numbers.

## WHICH path was absent / divergence

There was no failing repetition, and neither measured path was absent in any of the 603 repetitions. Therefore the requested failing-repetition choice (configured path, CubDB path, or both) is not observable in this bounded run.

The raw strings `(b)` and `(c)` differ on every healthy repetition: `tmp/test_data` versus `tmp/test_data/commits`. That is not stale-path divergence; CommitStore deliberately starts CubDB in the `commits` child directory. At the comparable semantic level, CubDB's boot-captured path equalled `Path.join(configured_data_dir, "commits")` throughout, so it did not diverge from the repetition's configured path.

## Compaction near-miss

Background compaction was visible without a red. Full `.compact` names observed across the runs were `1D.compact` through `29.compact`, then `2A.compact` through `2F.compact` (with some gaps only because the probe samples once per repetition). The CubDB directory stayed present and listable while those files appeared and were promoted to `.cub` files.

## Artifacts

- `mech-instrumented.diff`: exact temporary instrumentation diff
- `mech-compile.log`: `mix compile --warnings-as-errors`, exit 0
- `mech-invocation-01.log`: 201 `CX_SNAPMECH` lines, 201 green verdicts
- `mech-invocation-02.log`: 201 `CX_SNAPMECH` lines, 201 green verdicts
- `mech-invocation-03.log`: 201 `CX_SNAPMECH` lines, 201 green verdicts

The test file was restored by `cp` from the pre-edit backup. `cmp` returned 0 and `git diff -- apps/commonplace_cli/test/commonplace/cli/snapshot_test.exs` was empty afterward.

## Brief discrepancies

1. `(b)` and `(c)` are paths at different abstraction levels. Literal inequality cannot be the claimed one-read stale-path discriminator because healthy operation necessarily reports `tmp/test_data` and its `commits` child.
2. As s1 already reported, `--repeat-until-failure 200` yields 201 observable repetitions when green, not 200.
3. The same numeric pids recur across separate invocations because each fresh BEAM allocates them similarly; pid stability can only be concluded within an invocation, not across VM lifetimes.

No fix, product-code change, assertion change, setup/teardown repair, deletion, cleanup, live-store access, serve access, or provocation was performed.
