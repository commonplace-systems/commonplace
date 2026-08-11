# S10-disc diff_yjs oracle measurement — 2026-08-11

Measurement only. No fixes were made.

## Fixture install

Command:

```text
npm ci --prefix apps/yelixer/test/fixtures
```

Exit status: `0`

Output tail:

```text
added 4 packages, and audited 5 packages in 959ms

4 packages are looking for funding
  run `npm fund` for details

found 0 vulnerabilities
```

## Stable oracle enclosure

| Field | Measurement |
|---|---|
| Node version | `v24.13.1` |
| Driver path | `/home/jes/sol-s10/apps/yelixer/test/fixtures/yjs_diff_driver.mjs` |
| Oracle arm | `stable` (default) |
| Command | `mix test apps/yelixer/test/yelixer/diff_yjs_test.exs` |
| Count | 11 tests ran; 0 failures |
| Duration | 2.4 seconds (ExUnit-reported) |
| 11-ran assertion | **PASS — exactly 11 tests ran** |

| # | Test identity | Result |
|---:|---|---|
| 1 | `text: insert → encode → reload → content matches yjs` | PASS |
| 2 | `text: insert → delete from start → reload matches yjs` | PASS |
| 3 | `text: insert → delete-all → insert new → reload matches yjs` | PASS |
| 4 | `text: 5 cycle rehydrate with appends matches yjs` | PASS |
| 5 | `map: set keys → reload → content matches yjs` | PASS |
| 6 | `map: set → reload → overwrite → reload matches yjs` | PASS |
| 7 | `map: set → reload → delete key → reload matches yjs` | PASS |
| 8 | `array: push → reload → push more matches yjs` | PASS |
| 9 | `array: push → reload → delete first → insert replacement matches yjs` | PASS |
| 10 | `envelope (root map + content text, the CX-2sv pattern): insert text with root metadata → reload → replace content matches yjs` | PASS |
| 11 | `envelope (root map + content text, the CX-2sv pattern): envelope + delete-from-start matches yjs` | PASS |

## Preview oracle enclosure

| Field | Measurement |
|---|---|
| Node version | `v24.13.1` |
| Driver path | `/home/jes/sol-s10/apps/yelixer/test/fixtures/yjs_diff_driver.mjs` |
| Oracle arm | `preview` (`YJS_ORACLE=preview`) |
| Command | `YJS_ORACLE=preview mix test apps/yelixer/test/yelixer/diff_yjs_test.exs` |
| Count | 11 tests ran; 0 failures |
| Duration | 3.5 seconds (ExUnit-reported) |
| 11-ran assertion | **PASS — exactly 11 tests ran** |

| # | Test identity | Result |
|---:|---|---|
| 1 | `text: insert → encode → reload → content matches yjs` | PASS |
| 2 | `text: insert → delete from start → reload matches yjs` | PASS |
| 3 | `text: insert → delete-all → insert new → reload matches yjs` | PASS |
| 4 | `text: 5 cycle rehydrate with appends matches yjs` | PASS |
| 5 | `map: set keys → reload → content matches yjs` | PASS |
| 6 | `map: set → reload → overwrite → reload matches yjs` | PASS |
| 7 | `map: set → reload → delete key → reload matches yjs` | PASS |
| 8 | `array: push → reload → push more matches yjs` | PASS |
| 9 | `array: push → reload → delete first → insert replacement matches yjs` | PASS |
| 10 | `envelope (root map + content text, the CX-2sv pattern): insert text with root metadata → reload → replace content matches yjs` | PASS |
| 11 | `envelope (root map + content text, the CX-2sv pattern): envelope + delete-from-start matches yjs` | PASS |

## Factual summary

The stable arm ran all 11 named tests and recorded 11 passes and 0 failures. The preview arm ran the same 11 named tests and recorded 11 passes and 0 failures. Neither arm was skipped.

## Deviations

None. The fixture-scoped `npm ci` installed both oracle aliases. The existing `deps` symlink points to `/home/jes/commonplace/deps`; compilation completed without needing to write there, so no dependency-tree copy and no `MIX_DEPS_PATH` or `MIX_BUILD_PATH` override was used.
