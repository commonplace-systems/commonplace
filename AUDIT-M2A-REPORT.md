# AUDIT-M2A measurement report

## Outcome

**Honest split at HEAD:** none of the three measured HEAD semantics reproduces
the incident's combination of a continuous 25.5-hour storm, zero suppression
summaries, and only five organic admissions.

- A continuously active same-bucket storm emitted exactly one summary for each
  crossed suppressed window: `windows_crossed=5 summaries_expected=5
  summaries_in_doc=5`.
- Killing a deliberately arranged disposable ETS owner did erase the current
  bucket's `95` accumulated suppressions without a summary, but the resulting
  table rebirth admitted `20` extra organic records. Organic capture was `85`
  with rebirth versus `65` without that rebirth, not the incident's `5` total.
- Stopping the stream stranded its final `80` suppressions even after an
  expired timestamp and a different-bucket event, but this accounts for exactly
  one missing summary per stopped stream, not approximately 1,500.

**Verdict:** HEAD's rollover semantics require a killer to explain the
incident's zero summaries; owner death can destroy suppression state but cannot
thread zero summaries without over-admitting under a continuing storm; stream
stop can hide only the final window. The incident's zero-summaries remains
unexplained by these candidates.

No production code was changed. The measurement harness is
`apps/commonplace/test/commonplace/trust/audit_m2a_measurement_test.exs`, is
excluded from the ordinary suite by `:scale`, and was run arm-by-arm in the
mandated order before a final combined run.

## HEAD and fixture

HEAD was `3bcd585170f6d9cad0261f47017eb7d2daa262f9` on
`sol/m0qw-audit-m1`, the committed M1 branch named by
the brief.

The harness reuses M1's real-pipeline fixture: a test-owned temporary data
directory, successful node signing identity mint asserted before strict
enforcement, real store, real dispatcher, unsigned `CommitStore.create_commit/5`
denials, the real telemetry handler and rate gate, dispatcher flush, and real
red-log substrate readback scoped by dispatcher boot id. Bucket window starts
are backdated solely to cross clock boundaries; counts and suppression
arithmetic come from the driven events.

Every arm ended with the handler attached, `handler_failed=0`, and dispatcher
`shed=failed=queued=in_flight=0`; dispatcher `offered` equalled both stage
`offered` and substrate `recorded` at quiescence.

## Arm 1 — multi-window continuous storm baseline

Each measured window received 100 real local-write denials against a cap of 20:
20 admissions and 80 suppressions. After the initial filled window, the harness
crossed five boundaries. Each crossing was followed by another same-bucket
storm, so each closed suppressed window had the event required to trigger its
rollover summary.

| windows crossed | summaries expected | summaries in doc | per-summary `suppressed` | suppressed sum |
|---:|---:|---:|---|---:|
| 5 | 5 | 5 | `[80, 80, 80, 80, 80]` | 400 |

| entered | built | guarded | rate-suppressed | offer-events | offered records | recorded | organic captured | shed | failed |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 600 | 600 | 0 | 480 | 120 | 125 | 125 | 120 | 0 | 0 |

The arithmetic closes:

```text
600 entered = 0 guarded + 480 rate_suppressed
            + 120 offer_events + 0 handler_failed

125 offered records = 120 organic records + 5 summaries
```

Result: `M=N`, exactly rather than approximately for these five fully
suppressed crossed windows. HEAD emits per-window during a continuous
same-bucket storm. A 25.5-hour continuously active storm spans about 1,530
one-minute windows; endpoint placement can change the count by one, not reduce
it to zero.

## Arm 2 — owner death, both sides of the tension

### Ownership topology measured

The existing named table had an attach-time owner before any test denial. To
measure the proposed disposable-owner topology without killing the store, the
harness deleted the public table, fired the first same-name telemetry event
directly from a disposable process, and confirmed that process owned the
recreated table. It then drove all organic events through real
`CommitStore.create_commit/5` denials.

The initial event plus 14 real low-frequency denials consumed 15 permits. The
next 100 real organic denials therefore produced the M1-shaped five organic
captures and 95 suppressions. The harness killed and monitored the disposable
owner, observed `:ets.whereis(@rate_table) == :undefined`, then continued the
real storm. The next real denial recreated the table, now owned by the real
CommitStore firing process.

### Suppression side

| state | accumulated suppressed | summaries carrying it |
|---|---:|---:|
| immediately before owner death | 95 | 0 |
| after owner death and table disappearance | state erased | 0 |
| three later crossed windows | 80 each | 3 |

The summaries in the document were `[80, 80, 80]`, sum `240`. No summary
carried the erased `95`. Owner death therefore really can silently destroy one
live table's accumulated suppression state.

### Organic-admission side

| quantity | organic captures |
|---|---:|
| before owner death, after 15-permit prefill | 5 |
| expected over the same later crossed windows without a rebirth | 60 |
| no-rebirth total | 65 |
| fresh admissions opened by the rebirth | 20 |
| measured total with rebirth | 85 |

| entered | built | guarded | rate-suppressed | offer-events | offered records | recorded | low-frequency captured | organic captured | summaries |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 515 | 515 | 0 | 415 | 100 | 103 | 103 | 15 | 85 | 3 |

The stage identity closes: `515 = 0 + 415 + 100 + 0`. The three summaries
explain the record/event difference: `103 offered records = 100 offer-events +
3 summaries`.

Result: the pre-declared tension cuts against the candidate quantitatively. A
single mid-window rebirth after the ticket-shaped five admissions opened 20
more. Repeated owner deaths capable of preventing summaries throughout a
continuous 25.5-hour storm would repeatedly reopen admissions, not preserve an
organic total of five.

## Arm 3 — stream-stop bound

The harness drove 100 same-bucket denials, producing 20 records and leaving 80
suppressions. It then backdated that bucket beyond expiry but stopped that
stream. A real different-bucket telemetry event was fired and persisted; it did
not inspect or flush the stale storm bucket.

| storm entered | storm captured | storm suppressed and stranded | different-bucket captured | summaries before different event | summaries after different event |
|---:|---:|---:|---:|---:|---:|
| 100 | 20 | 80 | 1 | 0 | 0 |

The combined stage counts were `entered=101`, `rate_suppressed=80`,
`offer_events=21`, `offered=21`, and `handler_failed=0`. Dispatcher offered and
recorded were both 21 with no loss.

Result and bound: rollover is lazy and bucket-local. If a stream ends, its last
window has no later same-bucket event to produce a summary. Stream death thus
explains exactly **one** missing summary per stream, never approximately 1,500
missing summaries from one continuous stream.

## Candidate discriminations

### Summary generation semantics

Ruled out as the zero-summaries mechanism for a continuous same-bucket storm.
Five crossed windows produced five summaries with exact suppression arithmetic.

### Rate-table owner death

One deliberately arranged owner death reproduced silent loss of one bucket's
95 accumulated suppressions. It failed the organic constraint immediately:
rebirth admitted 20 extra organic records after the measured five.

### Stream stop

Reproduced one missing final-window summary and no cross-bucket flush. Its
one-per-stream bound is roughly three orders of magnitude short of the
25.5-hour storm's expected summary count.

## M2 candidate (not landed)

No fix is proposed as the incident mechanism is still unproven. The measured
design exposures are nevertheless concrete: table lifetime currently controls
whether accumulated suppression accounting survives, and summaries are emitted
only by a later same-bucket event. A future fix round could separately evaluate
long-lived supervised ownership (or an ETS heir) and an explicit periodic/final
flush. Neither is evidence for what happened on the incident boot, and neither
was implemented here.

## Discrepancies and near-misses

1. The brief calls the table "first-caller-owned" and says the owner is the
   process that fired the first denial. At HEAD, `AuditLog.attach/2` calls
   `ensure_rate_table/0`, so an ordinary attached boot can create and own the
   table before any denial. The harness observed a pre-existing attach-time
   owner.
2. The brief suggests that a spawned caller can fire the first real denial,
   own the table, and be killed without disturbing the store. For
   `CommitStore.create_commit/5`, the telemetry event is emitted inside the
   CommitStore's `handle_call`; the store, not the calling client, is the firing
   process. The disposable-owner topology therefore required one direct
   telemetry event. After that owner died, the next real denial recreated the
   table with the CommitStore as owner; killing that owner would disturb the
   store. This makes the proposed topology a controlled candidate test, not the
   normal boot topology asserted by the brief.
3. Arm 1's expected count was not merely approximate under the specified
   conditions: every crossed suppressed window followed by a same-bucket event
   produced exactly one summary, `5/5`.
4. M1 reported a complete path-split population of 3,148 tests plus 5 doctests,
   but the retained M1 store line was `5 doctests, 468 tests, 0 failures`. The
   brief correctly warned that M1's anchored summation dropped that entire
   partition. Adding those 468 and this round's three excluded tests gives the
   correctly parsed M2A population of `3,619 tests + 5 doctests`.
5. The M1 `155/155` live-boot counter and 107 storm-boot rows are carried as
   cross-boot facts exactly as corrected by this brief. This round did not
   reopen that resolved pairing.

## Commands and results

```text
mix test test/commonplace/trust/audit_m2a_measurement_test.exs:83 --include scale --seed 0
3 tests, 0 failures, 2 excluded — arm 1 passed

mix test test/commonplace/trust/audit_m2a_measurement_test.exs:119 --include scale --seed 0
3 tests, 0 failures, 2 excluded — arm 2 passed

mix test test/commonplace/trust/audit_m2a_measurement_test.exs:216 --include scale --seed 0
3 tests, 0 failures, 2 excluded — arm 3 passed

mix format --check-formatted test/commonplace/trust/audit_m2a_measurement_test.exs
passed

mix test test/commonplace/trust/audit_m2a_measurement_test.exs --include scale --seed 0
3 tests, 0 failures

mix compile --warnings-as-errors
passed

commonplace path split: every entry under test/commonplace/*, then
test/commonplace_test.exs and test/mix/, each in its own Mix invocation
86 invocations; 3,619 tests + 5 doctests, 0 failures, 21 excluded, 1 skipped
```

The path-split total was computed from the last complete ExUnit summary in each
of 86 retained per-entry logs, parsing every numeric noun independently so
`5 doctests, 468 tests, 0 failures` and singular `1 test` forms are included.
Logs are retained under `/tmp/AUDIT-M2A-logs/` for this worktree session.

The `commonplace` app defines no `mix precommit` alias, so its required gates
were run explicitly. No live/default data directory was contacted, no fix was
made, and `lib/` was not modified.

The work-product stat (computed for the two untracked outputs against
`/dev/null`) is:

```text
AUDIT-M2A-REPORT.md                                                   | 256 +
apps/commonplace/test/commonplace/trust/audit_m2a_measurement_test.exs | 354 +
2 files changed, 610 insertions(+)
```

The supplied `AUDIT-M2A-BRIEF.md` was already untracked at entry and remains
unmodified; it is not part of the work-product stat. All work remains unstaged.
