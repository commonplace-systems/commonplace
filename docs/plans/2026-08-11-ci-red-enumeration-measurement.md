# CI-red enumeration measurement

## Total test counts and durations

- Seed 101: 4,352 tests; reported aggregate duration 606.2 seconds; command `mix test --seed 101 > run-seed101.log 2>&1; echo "rc=$?"`; `rc=2`.
- Seed 202: 4,352 tests; reported aggregate duration 629.9 seconds; command `mix test --seed 202 > run-seed202.log 2>&1; echo "rc=$?"`; `rc=2`.
- Seed 303: 4,352 tests; reported aggregate duration 650.3 seconds; command `mix test --seed 303 > run-seed303.log 2>&1; echo "rc=$?"`; `rc=2`.

| test identity | red in seeds | alone | same-seed repeat (with N) | enclosure refs / flags |
|---|---|---|---|---|
| `apps/yelixer/test/yelixer/diff_yjs_test.exs:44` — `Yelixer.DiffYjsTest: failure on setup_all callback, all tests have been invalidated` | 101, 202, 303. Commands: `mix test --seed 101 > run-seed101.log 2>&1; echo "rc=$?"`; `mix test --seed 202 > run-seed202.log 2>&1; echo "rc=$?"`; `mix test --seed 303 > run-seed303.log 2>&1; echo "rc=$?"` | red; 11 tests, 0 reported failures, 11 invalid; 0.3 seconds; `rc=2`. Command: `mix test apps/yelixer/test/yelixer/diff_yjs_test.exs > alone-diff-yjs.log 2>&1; echo "rc=$?"` | not run; alone was red | `enclosure-seed101.txt`; `enclosure-seed202.txt`; `enclosure-seed303.txt`; `enclosure-alone-diff-yjs.txt`. FLAG: each umbrella extracted 1 failure identity while its summary reported 0 failures and command returned `rc=2`. FLAG: alone extracted 1 failure identity while its summary reported 0 failures and command returned `rc=2`. Mechanical annotation command, applied to the captured failure block in each of `run-seed101.log`, `run-seed202.log`, `run-seed303.log`, and `alone-diff-yjs.log`: `grep -E "untrusted_root\|anchor\|signing\|trust_rejected\|no_signing_context"`; no match in any block, so no `possible fence artifact` annotation. |

## Deviations

- Before the recorded seed 101 run, an initial seed 101 attempt returned `rc=1` before reporting a test total. That attempt is VOID. Its raw output is `run-seed101-void-compile.log`, and its enclosure record is `enclosure-seed101-void-compile.txt`.
- Seed 101: 1 extracted failure identity; summary reported 0 failures; command returned `rc=2`. Row flagged.
- Seed 202: 1 extracted failure identity; summary reported 0 failures; command returned `rc=2`. Row flagged.
- Seed 303: 1 extracted failure identity; summary reported 0 failures; command returned `rc=2`. Row flagged.
- Alone file run: 1 extracted failure identity; summary reported 0 failures; command returned `rc=2`. Row flagged.
- The three umbrella total test counts match: 4,352 each.
- No run began with 1-minute load above 2.0. Required pre-run delays were applied where the observed load exceeded 2.0.

