# S8-disc yrs assertion census results

Measurement date: 2026-08-11 UTC

## Control enclosure

| Field | Result |
|---|---|
| Command | `env MIX_DEPS_PATH=/tmp/sol-s8-census-deps MIX_BUILD_PATH=/tmp/sol-s8-census-build /usr/bin/time -f '\nCENSUS_WALL_SECONDS=%e\nCENSUS_MAX_RSS_KB=%M\nCENSUS_EXIT=%x' mix test apps/yelixer/test/yelixer/yrs_dataset_test.exs --seed 0 > tmp/s8-disc-census/control-local-deps.log 2>&1` |
| Seed | `0` |
| Dataset cases | `5,320` (nonzero) |
| Text-validation iterations | `5,320` |
| Full text/map/array-validation iterations | `100` |
| ExUnit result | `2 tests, 0 failures` |
| Dataset execution duration | `28.3s` |
| Command wall duration | `128.30s` |
| Exit | `0` |

## Widened census enclosure

| Field | Result |
|---|---|
| Command | `env MIX_DEPS_PATH=/tmp/sol-s8-census-deps MIX_BUILD_PATH=/tmp/sol-s8-census-build YELIXER_YRS_FULL_CENSUS=1 /usr/bin/time -f '\nCENSUS_WALL_SECONDS=%e\nCENSUS_MAX_RSS_KB=%M\nCENSUS_EXIT=%x' mix test apps/yelixer/test/yelixer/yrs_dataset_test.exs --seed 0 > tmp/s8-disc-census/widened.log 2>&1` |
| Seed | `0` |
| Dataset cases | `5,320` (nonzero assertion passed) |
| Text-validation iterations | `5,320` |
| Full text/map/array-validation iterations | `5,320` |
| ExUnit result | `2 tests, 0 failures` |
| Dataset execution duration | `49.6s` |
| Command wall duration | `51.86s` |
| Control-to-widened dataset-duration delta | `21.3s` |
| Exit | `0` |

## Failure census

| Case | Assertion kind | One-line failure shape |
|---|---|---|

Verified empty: no failure identities were emitted by the widened run.

The complete widened output is in `tmp/s8-disc-census/widened.log`. Failure identities were extracted to `tmp/s8-disc-census/widened-failure-identities.tsv`; `wc -l` reported `0`, and the file was asserted empty with `test ! -s`.

## Reconciliation

Identity rows extracted: `0`. Reported failures: `0`. Reconciliation: `0 == 0` (exact).

The decoded fixture count is nonzero: the leading varint bytes are `200 41`, which decode as `(200 &&& 127) + (41 <<< 7) = 5,320`. The fixture size is `1,655,342` bytes.

## Gate

`env MIX_DEPS_PATH=/tmp/sol-s8-census-deps MIX_BUILD_PATH=/tmp/sol-s8-census-compile-build mix compile --warnings-as-errors` exited `0`. Full output is in `tmp/s8-disc-census/compile.log`.

## Deviations

- The first control command, using the repository's shared `deps` symlink, stopped before ExUnit because Phoenix compilation attempted to write under the read-only `/home/jes/commonplace/deps`. Its complete log is `tmp/s8-disc-census/control.log` (exit `1`, wall `86.64s`). The unchanged control was then run successfully with a copied, writable dependency tree and an isolated build path.
- The successful control wall duration includes compilation into the isolated build path. The widened wall duration used that warmed path; both raw wall times and ExUnit dataset durations are therefore reported without treating the wall-time difference as a like-for-like dataset cost.
- `mix format --check-formatted apps/yelixer/test/yelixer/yrs_dataset_test.exs` reports pre-existing formatting differences across the test file. No unrelated formatting changes were made.
- The brief's stale `QUEUE.md` reference was replaced by the operator-provided root `CX-xqfw-ticket.md` source, as directed.
