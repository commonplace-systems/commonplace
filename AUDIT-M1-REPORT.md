# AUDIT-M1 measurement report

## Outcome

**Honest negative at HEAD:** the real pipeline can reproduce the bare
`148647 -> 5` organic count only with a deliberately pre-consumed rate bucket,
but that candidate predicts a suppression summary of `148642`, not the observed
`5`. It therefore does not reproduce the measured shape and is not named as the
incident mechanism.

No production code was changed. The measurement harness is
`apps/commonplace/test/commonplace/trust/audit_m1_measurement_test.exs` and is
excluded from the ordinary suite by its existing `:scale` tag.

## HEAD measurement

HEAD was `06874b6db49a8bc9ab5c032538f0839137675737`.

The harness uses a test-owned temp data directory, explicitly mints its node
signing identity before strict enforcement, starts a real store and dispatcher,
and drives unsigned `CommitStore.create_commit/5` calls. Every call is refused
by the real local-write gate and fires the real telemetry event inside the store
process. Capture is read back from the real red-log audit document after the
dispatcher flushes.

### Clean-bucket storm

| driven | entered | built | guarded | rate-suppressed | offer-events | handler-failed | dispatcher offered | recorded | shed | captured |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 148647 | 148647 | 148647 | 0 | 148627 | 20 | 0 | 20 | 20 | 0 | 20 |

Red-first number: `driven=148647 captured=20 lost_at_stage=rate_gate:148627`.

The handler was attached before and after. The stage identity closes exactly:

```text
148647 entered = 0 guarded + 148627 rate_suppressed
               + 20 offer_events + 0 handler_failed
```

### Mixed shape, before rollover

The same event-name bucket was first given 15 low-frequency denials on one doc,
then 148,647 high-frequency denials on a second doc, all within one real
60-second window.

| stream | driven | captured | capture rate |
|---|---:|---:|---:|
| low-frequency prefill | 15 | 15 | 100% |
| organic storm | 148647 | 5 | 0.003364% |
| total | 148662 | 20 | 0.01345% |

| entered | built | guarded | rate-suppressed | offer-events | handler-failed | dispatcher offered | recorded | shed |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 148662 | 148662 | 0 | 148642 | 20 | 0 | 20 | 20 | 0 |

Red-first number for the ticket-shaped organic arm:
`driven=148647 captured=5 lost_at_stage=rate_gate:148642`.

The measured selection factor is `100% / 0.003364% = 29,729.4x`, close to the
reported approximately 25,000x asymmetry. This is an ordering effect, not a
document distinction: both documents consume the same 20-per-minute bucket
because the key is the telemetry event name.

### Rollover discriminator

After the storm, the harness preserves the real bucket's count and suppression
arithmetic but advances only its window timestamp to avoid a one-minute test
sleep. One further real denial takes the real rollover branch.

| entered | rate-suppressed | offer-events | handler-failed | dispatcher offered | recorded | shed | summaries | summary `suppressed` |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 148663 | 148642 | 21 | 0 | 22 | 22 | 0 | 1 | 148642 |

The extra event offers two records by construction: the summary and its own
payload. This is why `offered=22` while `offer_events=21`.

## Candidate discriminations

### Loss upstream of the handler

Discriminator: `entered < driven`.

Result: ruled out at HEAD for both shapes. `entered == driven` exactly.

### Telemetry-handler detachment

Discriminator: attachment changes during the storm or `handler_failed` rises.

Result: ruled out at HEAD. The handler remained attached and
`handler_failed=0` through 297,310 real denials across the two arms.

The existing faithful legacy-inline control was also run. It reproduced the
historical `:calling_self` exit and telemetry immediately detached the handler.
That mechanism loses the first record and every later record; it predicts an
empty dispatcher/audit stream and a dead canary, not 5 organic captures beside
102 green canaries. It is therefore not this incident's shape.

### Dispatcher overload or persistence failure

Discriminator: nonzero `shed`, `failed`, `queued`, or `in_flight`, or
`offered != recorded` at quiescence.

Result: ruled out for the measured harness. Both shapes ended with
`shed=failed=queued=in_flight=0` and `offered=recorded`.

### Shared event-name rate bucket

Discriminator: two document streams compete for the same 20 permits, and the
post-window summary reports every suppressed event.

Result: both properties reproduced. Fifteen low-frequency events left exactly
five permits for the organic doc, but the sole summary necessarily reported
`148642` suppressed events. The ticket instead reports that the sole summary in
the entire audit document had `suppressed: 5`.

**Verdict:** shared event-name fixed-window rate limiting reproduces the bare
five-capture number and the selection factor under the tuned shape
`15 low-frequency events -> 148647-event sub-minute storm`, but it does **not**
predict the observed suppression-summary magnitude. It is a near-match and is
not named as the mechanism.

## Archaeology

The measured boot began at 2026-08-06 22:11 UTC. The as-of state selected by
`git log --until=2026-08-07 -- apps/commonplace/lib/commonplace/trust/` is:

- `af225814d988b23ee7ce0fe717d2b4db61a13da2`, committed
  2026-08-06 11:08 UTC: async dispatcher, node-signed audit writes, recursion
  guard, and catch-all handler that swallows exits instead of detaching.
- `1f7a66e5cb983b2240b179ea99b85250479e130a`, committed
  2026-08-06 11:40 UTC: test-only sanctioned reset for the already-existing
  global rate table. It did not change production event handling.

Thus the robust async/catch-all implementation predates the measured process
start by about eleven hours. The later relevant changes add denominator
accounting, firing-process/writer fields, per-stage instrumentation, and one new
audited event. The diff from `af225814` to HEAD contains no later change that
closes a handler-detach, rate-gate, dispatcher-shed, or audit-write persistence
window.

There is consequently **no honest closing SHA to name from repository
archaeology**. The pre-`af225814` inline implementation does reproduce permanent
detach, but it fails the incident's canary and capture constraints. Claiming
`af225814` closed this measured boot would contradict commit and boot time.

The next discriminating archaeological evidence is deployment identity, not
another source-level story: the loaded `AuditLog`/`AuditDispatcher` BEAM module
hashes or release/build identity for the measured process, plus a timestamp
histogram for the 148,647 denials and the five captured organic records. Those
facts are not present in the brief and the live store/log is explicitly outside
this round's permitted surface.

## Discrepancies and limits

1. The brief calls for a mechanism that predicts all four constraints, but its
   quoted `suppressed: 5` summary falsifies the only HEAD mechanism that produces
   `148647 -> 5` in the real pipeline.
2. `155 offered / 155 recorded` says 155 records were successfully persisted by
   that dispatcher instance, while the quoted same-boot audit-document count is
   107. Without a scope explanation, those two claims do not have count parity.
3. Source archaeology finds the hardened implementation already present before
   the measured boot and finds no subsequently landed behavioral closing change.
   The brief's anticipated “pre-X tree / closing change” branch does not exist in
   the repository history examined.
4. The rollover timestamp is accelerated in the test; bucket occupancy,
   suppression count, real handler branch, dispatcher, signed persist, and
   substrate readback are not mocked.
5. The first attempted run was invalid because the temp directory had not yet
   minted a node identity. It was stopped and discarded. The final harness makes
   successful key minting a setup assertion and produced `failed=0`.

No fix candidate is proposed: the incident mechanism remains unproven.

## Commands and results

```text
mix test test/commonplace/trust/audit_m1_measurement_test.exs --include scale --seed 0
2 tests, 0 failures (75.7s)

mix test test/commonplace/trust/audit_dual_mechanism_test.exs:231 --seed 0
12 tests, 0 failures, 11 excluded
observed: Class=:exit, Reason={:calling_self, ...}, handler detached

mix compile --warnings-as-errors
passed

commonplace path split: every entry under test/commonplace/*, then
test/commonplace_test.exs and test/mix/, each in its own Mix invocation
3148 tests + 5 doctests, 0 failures, 18 excluded, 1 skipped
```

The first store-partition run found 30 salvage rows where its deterministic
seed-0 fixture expected 20. Nine stale test-owned salvage directories were
present in `/tmp`; they were moved to a recoverable `/tmp` trash directory.
The complete store partition then passed with 468 tests + 5 doctests. This
retry is included in the zero-failure total above; the initial contaminated
result is not silently counted green.

The `commonplace` app defines no `mix precommit` alias. Its required gates were
therefore run explicitly rather than substituting the web app's unrelated
precommit alias.
