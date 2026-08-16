# Negative-arm precondition audit — and the instrument that could not count

**Date:** 2026-08-16 · **Round:** S85 + follow-up · **File:**
`apps/commonplace/test/commonplace/store/sla_tombstone_test.exs`

## What the round was for

Ceremony arm 10 read *"pre-activation registrations are refused, not
retroactively trusted"*. It passed for its whole life. It never constructed the
state its name described — its "pre-existing tombstone" was never registered,
because the pre-anchor store attempt returned `:no_eviction_anchor_configured`.

**The arm was refusing on ABSENCE, not on the property.**

The audit added, to each of the twelve arms, an assertion that the precondition
state EXISTS before the forbidden act is attempted. This is *"prove the corpus
was non-empty"* applied to test setup.

## Finding 1 — the count

```
1 of 12 negative arms were refusing on absence   (arm 10)
```

**This is a LOWER BOUND, not an estimate.** The twelve are the most recently
written and most heavily reviewed negative arms in the codebase. Their defect
rate cannot be generalised downward to the other ~89 negative assertions: they
can PROMOTE a sweep, never DEMOTE it. Arm 10's defect appeared in the arms that
had the most care spent on them.

Arm 10's defect was found ONLY by PERTURBATION. Three readings of the same arm,
each correcting the last: a source read concluded "unsatisfiable"; a rehearsal
concluded "fires on the verify path"; only changing activation revealed the
tombstone was never stored. **READ < RUN < PERTURB.**

## Finding 2 — the instrument could not have reported a number above 1

**All twelve preconditions live in a single test function.** ExUnit aborts a
test at its first failing assertion.

⇒ **The first failing precondition MASKS every arm after it.** `k of 12` was
never measurable in one run; the audit reports the FIRST failure and stops.

This was not deduced — it was observed. Retiring arm 10 did not turn the file
green: it turned a failure at arm 10 into a failure at arm 12, which had been
failing invisibly the entire time.

**The honest statement of the result within a single run is therefore:**

```
AT LEAST 1 of 12 were refusing on absence, and the instrument cannot count higher.
```

A count that cannot exceed one is not a count. It was relayed as one before this
was noticed. Boss's pre-registrable test for the recurrence: **"can this
instrument report a number greater than one? If no, it is a FINDER, not a
COUNTER, and its output must never be written with a denominator."**

### But masking does not survive iteration

Abort-on-first-failure masks within ONE RUN. It does not make the arms behind it
permanently unexamined:

```
run 1   arm 10  FAILS  -> retired (ruled)            arms 11, 12 masked
run 2   arm 12  FAILS  -> precondition relocated     arm 11 passed, now visible
run 3   GREEN — 6 tests, 0 failures
```

A green run means every assertion before the end executed and passed. All 11
surviving preconditions ran and passed in run 3.

⇒ **The twelve ARE audited — serially rather than in parallel.** The final count
for refusing-on-absence is **exactly 1**, and it is a complete result for these
arms. The bound was on the instrument's ability to COUNT, and iteration escaped
it; the cost is that each finding takes a whole run to surface.

This distinction matters for scheduling: re-running this audit with independent
preconditions would re-derive what run 3 established. The report-all requirement
belongs in briefs for arms not yet examined.

**Consequence for any follow-on sweep:** a brief that adds preconditions to a
group of arms must require that a failing precondition does NOT abort the
remaining arms — collect and report all of them, or split them so each can fail
independently. Otherwise the sweep inherits this blindness and a clean-looking
result means only "the first one passed."

## Finding 3 — a precondition that measured a later world than the act it guards

Arm 12's precondition re-read the tombstone with
`get_sla_tombstone_for_commit/2` **after** arm 11 revokes the anchor, where that
read is *correctly* refused with `{:revoked_eviction_anchor, _}`. The read it
actually guards runs earlier, before the revocation, and succeeds.

**A precondition that measures a later world than the act it guards is not a
precondition.** Fixed by moving it adjacent to its read, with the reason
recorded at the site. The arm's own assertion was not touched — the correction
was to the precondition, never to the behaviour under test.

This is not a second instance of refusing-on-absence. The refusing-on-absence
count remains 1.

## Arm 10 — retired, not deleted

Ruled by `commonplace-plan`. Both clauses of arm 10's name were checked before
retiring it, rather than accepting redundancy on the strength of the name:

| clause | successor |
| --- | --- |
| "pre-activation registrations refused" | `{:tombstone_registered_before_anchor_activation, registration, activation}` — directly |
| "not retroactively trusted" | adding an anchor cannot MOVE a registration that already sits before the activation position — a positional fact |

The successor **constructs** the state: it writes the registration event,
positions the tombstone before the activation, asserts the activation position
exists, and only then verifies. Confirmed at source and then at runtime:

```
EVICTION_ACTIVATION_BEFORE_RESULT={:error, {:tombstone_registered_before_anchor_activation, …}}
```

⭐ **Coverage is a property of STATES REACHED, not of NAMES PRESENT.** Retiring
arm 10 drops no coverage: it drops a name that never had a state behind it.

**Honest qualification, kept deliberately:** both arms aim at a state production
can no longer reach. The difference is not reachability but CONSTRUCTION —
defence-in-depth against a bricked door, declared as such. Glossing that would
let a bricked-door test read as a live guard, and the retirement rests on the
distinction.

The struck line stays in the test with its successor named, so the 12 → 11
history remains legible: **retiring a failing arm and deleting an inconvenient
one must not produce the same artifact.**

## Attribution of the two reds seen while landing this

Landing the retirement produced `3521 / 2` on `apps/commonplace`. Neither
failure was a clean known-red, so both were treated as mine until proven
otherwise. Attribution took five runs and two changes of instrument.

```
run 1  change present   3521 / 2   seed 117514  DIRTY   ← DeniedWriteReporting + GitBridge
run 2  change REVERTED  3521 / 0   seed 117514  DIRTY
run 3  change present   3521 / 0   seed 117514  DIRTY   ← same arm as run 1 ⇒ NONDETERMINISM
run 4  change REVERTED  3521 / 0   seed 117514  DIRTY   ← uninformative, as pre-registered
```

Full-suite replication was the wrong instrument: 17 minutes per run for one
bit, while the outcome that settles attribution — a **red on the control arm** —
is the rare one. Switched to `--repeat-until-failure` on the two files, run on
the unmodified tree.

**Both failures reproduced on a CLEAN tree (0 modifications):**

| test | repetition | failure |
| --- | --- | --- |
| `GitBridge.ServerTest` *"pause/resume: paused sync_now …"* | 13 | `GenServer.stop` → `no process` in `on_exit` |
| `DeniedWriteReportingTest` *"parent-schema registration …"* | 5 | `assert landed_count == 4` — **left: 5** |

⇒ **Neither failure is caused by this change.** Both are pre-existing and
nondeterministic.

**`GitBridge.ServerTest` has now shown the same `no process` teardown mechanism
in THREE distinct tests** — the known-red *"filters: __ / nosync / presence"*,
*"phantom-diff pin"*, and *"pause/resume"*. The mechanism is module-wide, which
is why known-reds must be recorded by MECHANISM and not by test name.

**`DeniedWriteReportingTest`'s write count is NONDETERMINISTIC — observed 4 and
5.** That is `CX-7rjn`: the test triggers its denial on the 4th write and selects
its target with `Enum.at(landed_docs, 3)`. When the count is 5 the assertion
fails loudly; when it is 4 but the sequence differs, the ordinal selects the
wrong document and the failure appears one line later as a MatchError on
`Schema.get_entry/2`. **Both observed failure shapes are one root.**

### ⛔ The hypothesis I killed was correct, and I killed it with one instance

Early on I proposed that a changed write count explained the failure, then
discarded it because `assert landed_count == 4` **passed** in run 1 — "the count
is the one thing that did not move." That was true of run 1's instance and false
of the mechanism.

⇒ ⭐ **Killing a hypothesis on a single instance is the same error as confirming
one on a single instance.** A nondeterministic mechanism will exonerate itself
in any given run.

### ⚠️ A confound avoided, recorded because it nearly fired

The targeted reproducer was almost launched alongside the still-running control.
The failure is load-dependent, so the extra load could have **induced** a red in
the clean arm — and that induced red would have looked exactly like the decisive
result being waited for. **When the phenomenon is resource-sensitive,
concurrency between experiments is itself a treatment.** All runs were kept
strictly serial.

## Why this was not landed red

The red was correct. That does not change what a red suite DOES to everyone who
sees it tomorrow: a gate that cries red gets routed around — least acceptable on
the suite the eviction ceremony ratifies against.
