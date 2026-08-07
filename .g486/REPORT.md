# CX-g486 report

## Result

Added `the DENY path's OFFERED work is bounded` to
`apps/commonplace/test/commonplace/trust/audit_choke_perf_test.exs`.
The baseline and attached arms both clear the sanctioned audit rate bucket
before each of 20 warm-up calls and 200 measured calls. The clear is outside
`:timer.tc`; exactly one deny call is inside it. The attached arm flushes the
dispatcher and requires its `offered` delta to equal all 220 calls. The test
also resets the suite-global bucket in `on_exit`.

The existing ALLOW and DENY-storm test bodies are byte-untouched.

## Red proof: resets removed

The deliberately vacuous version used the same warm-up-eats-the-bucket shape
as the storm arm. Command target:

```text
MIX_ENV=test mix test apps/commonplace/test/commonplace/trust/audit_choke_perf_test.exs:232
```

The sandbox required the Mix socket workaround described under anomalies.
Process exit: `2`. Verbatim output tail:

```text
DENY OFFERED path, n=200 per arm
  baseline    p50=459us p99=7750us calls=220
  with audit  p50=614us p99=9941us calls=220
  ratio       p50=1.338 p99=1.283
  offered     expected=220 observed=20



  1) test the DENY path's OFFERED work is bounded (Commonplace.Trust.AuditChokePerfTest)
     apps/commonplace/test/commonplace/trust/audit_choke_perf_test.exs:232
     200 attached deny calls were suppressed; the OFFERED-path timing is vacuous
     DENY OFFERED path, n=200 per arm
       baseline    p50=459us p99=7750us calls=220
       with audit  p50=614us p99=9941us calls=220
       ratio       p50=1.338 p99=1.283
       offered     expected=220 observed=20

     code: assert offered_delta == measured_calls,
     stacktrace:
       test/commonplace/trust/audit_choke_perf_test.exs:268: (test)


Finished in 0.8 seconds (0.00s async, 0.8s sync)
4 tests, 1 failure, 3 excluded
```

The bucket cap admitted exactly 20 attached warm-up calls. All 200 timed calls
were suppressed, and the destination-count guard detected every missing
offer.

## Green proof: per-call resets restored

Same command target after restoring the final implementation. Process exit:
`0`. Verbatim output tail:

```text
DENY OFFERED path, n=200 per arm
  baseline    p50=362us p99=3747us calls=220
  with audit  p50=683us p99=11253us calls=220
  ratio       p50=1.887 p99=3.003
  offered     expected=220 observed=220

.
Finished in 0.7 seconds (0.00s async, 0.7s sync)
4 tests, 0 failures, 3 excluded
```

## Full-file measurements

Captured from the single final full-file run (`4 tests, 0 failures`, exit 0):

| Arm | Baseline p50 / p99 | Attached p50 / p99 | Ratio p50 / p99 |
| --- | --- | --- | --- |
| DENY storm | 446us / 5652us | 547us / 7424us | 1.226 / 1.314 |
| DENY OFFERED | 661us / 3849us | 1601us / 24238us | 2.422 / 6.297 |

The OFFERED arm's asserted p50 ratio is `2.422 <= 3.0`. Its p99 ratio is
reported, not asserted, for the existing storm-arm rationale: one timed call
can queue behind a legitimate asynchronous dispatcher flush, whereas a
synchronous choke regression inflates the median.

Destination accounting in that same full run was exact:

```text
warm-up calls attached: 20
timed calls attached:   200
expected offered delta: 220
observed offered delta: 220
suppressed:               0
```

## Verification

- Full perf file: `4 tests, 0 failures`, exit 0; output was captured during
  execution and its measurements are transcribed above.
- Attach/reset scan: `1 test, 0 failures`, exit 0; output was captured during
  execution.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.

## Anomalies, unsmoothed

- This sandbox rejects the TCP sockets used by Elixir 1.18's Mix PubSub and
  OS-concurrency lock. `--no-listeners` alone still starts the PubSub
  subscriber. Runs therefore used a process-local no-op `Mix.PubSub` shim,
  `MIX_OS_CONCURRENCY_LOCK=0`, and a temporary writable dependency copy inside
  `.g486/`; no production or test source was changed for the workaround.
- The shared dependency checkout is read-only, while Phoenix's compile alias
  copies installer templates within its own tree. The temporary dependency
  copy was necessary for a clean test build and is removed before commit.
- The fresh compile emitted the third-party `uuid` package's existing
  `use Bitwise` deprecation warning while compiling that dependency; the
  warnings-as-errors command exited 0, and a subsequent no-op final compile
  is captured separately.
- Tail timings varied materially between the targeted green proof and the
  full-file run (OFFERED p99 ratio `3.003` versus `6.297`). No samples were
  removed or smoothed. This is the documented flush-collision behavior and
  is why p99 remains report-only.
- The deny calls log one warning each, so raw captured test output is noisy.
  Scratch capture files were removed after the required verbatim tails and
  measurements were transcribed into this report.
- The requested final commit could not be created in this sandbox. This
  worktree's `.git` indirection points to
  `/home/jes/commonplace/.git/worktrees/wt`, which is mounted read-only;
  `git add` failed while creating `index.lock`. The verified changes remain
  unstaged on `sol/cx-g486`, and `.sizing/` remains untouched.
- Beads status could not be updated because its Dolt server requires a local
  TCP listener and socket creation is forbidden by this sandbox.
