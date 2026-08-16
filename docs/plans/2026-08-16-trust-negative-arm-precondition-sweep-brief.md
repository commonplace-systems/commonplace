# Give the trust-surface negative arms a precondition: prove the state EXISTS before the forbidden act

> **Ruled by `commonplace-plan`.** Base: **the commit that adds this brief** —
> ⚠️ *not a sha.* **Build the worktree from that base.**

## Why these arms, and it is not their count

**Ceremony arm 10 read *"pre-activation registrations are refused, not
retroactively trusted"*. It passed for its entire life. It never constructed the
state its name described** — its "pre-existing tombstone" was never registered,
because the pre-anchor store attempt returned `:no_eviction_anchor_configured`.

⇒ ⭐⭐⭐ **THE ARM WAS REFUSING ON *ABSENCE*, NOT ON THE PROPERTY.**
⇒ ⛔ **The failure mode, named: *REFUSING FOR THE RIGHT-LOOKING REASON AT THE
WRONG STAGE.*** The atom is plausible, the arm is green, and nobody asks whether
the SETUP GOT FAR ENOUGH for the refusal to be about the property at all.

⚠️ **It survived two careful source readings and one rehearsal. Only PERTURBING
the mechanism exposed it.** ⭐ *READ < RUN < PERTURB.*

**These two files are chosen by BLAST RADIUS, not by count: they are the arms
whose green LICENSES A TRUST DECISION.**

## ⛔ The set, with the selector that produced it

⚠️ **The count below is stated WITH its pattern so you can re-derive it rather
than believe it.** ⭐ *An earlier version of this brief said "16 arms" with no
selector — a count without its selector is unreproducible, and the round would
have audited a set nobody specified.*

**Selector:** lines matching `assert.*{:error` · `refute ` · `assert_raise` ·
`== {:error`, attributed to the enclosing `test`.

```
apps/commonplace/test/commonplace/trust/capability_test.exs
    26 test functions · 10 negative arms across 10 DISTINCT tests

apps/commonplace/test/commonplace/trust/audit_dual_mechanism_test.exs
    12 test functions · 12 negative arms across 8 tests (3 tests hold 2 arms)

                                              TOTAL: 22 negative arms
```

⛔ **If your re-derivation gives a different number, REPORT THE DISCREPANCY and
audit what you find — do not force the set to 22.** The pattern is a starting
selector, not the definition of an arm.

## ⛔ What to build

**For EACH negative arm: BEFORE the forbidden act is attempted, ASSERT THE
PRECONDITION STATE EXISTS.**

⇒ ⭐ **This is *"prove the corpus was non-empty"* applied to TEST SETUP** — a law
this codebase already holds, in a habitat nobody had pointed it at.

**Per arm, ask: what must be true for the refusal to be ABOUT the property?
Assert that, then attempt the act.** *Examples of the shape:*
- an arm about a capability being refused ⇒ **assert the capability EXISTS and
  verifies** before asserting the refusal
- an arm about an audience binding ⇒ **assert the cert MINTS and the chain
  verifies**, so the denial cannot be "nothing was there"
- an arm about a scope ⇒ **assert the scope is POPULATED and the subject is
  inside it**

⛔ **Do NOT change what any arm asserts about the refusal. This round adds
preconditions; it does not re-specify behaviour.** ⚠️ *If adding a precondition
makes an arm fail, THAT IS THE FINDING — report it, do not adjust the arm to
match.*

### ⭐⭐ ASSERT THE PRECONDITION ADJACENT TO THE ACT IT GUARDS

⛔ **NOT at the top of the test, and NOT at the end.** A precondition placed
after later setup can measure a world that setup has already changed.

⚠️ **Measured instance, from the round that produced this brief:** an arm-12
precondition re-read a tombstone **46 lines and one REVOCATION** after the read
it guarded, where that read is *correctly* refused with
`{:revoked_eviction_anchor, _}`. The read it protected ran earlier and succeeded.
⇒ ⭐ ***A PRECONDITION THAT MEASURES A LATER WORLD THAN THE ACT IT GUARDS IS NOT
A PRECONDITION.***

## ⭐⭐ REPORT PRESENCE AND ABSENCE — not only what you added

⛔ **State, per arm, whether it ALREADY carried a precondition.**
⇒ ⭐ ***A survey that records only ABSENCES cannot tell a clean file from an
unexamined one*** — the two produce an identical report.

**Report shape:**
```
arm (test name)      already had a precondition?   added?   passes?
```

⚠️ **Hygiene, one sentence, and it binds on only 3 of the 22 here:** three tests
in `audit_dual_mechanism_test.exs` hold two arms each, and ExUnit aborts a test at
its first failing assertion — so a failure in the first arm masks the second
*within that run*. If a shared-test arm fails, note that its sibling was not
reached. ⭐ *This is not a general property of negative arms: it was a property of
one unusually-shaped file with twelve arms in a single test.*

## ⛔ Acceptance

1. **Every negative arm in both files carries a precondition assertion** naming
   what must exist for its refusal to be about the property.
2. ⭐⭐ **THE PER-ARM TABLE — presence, addition, result.** Absences alone are not
   a survey.
3. ⭐ **Any arm that FAILS once its precondition is asserted is REPORTED, not
   adjusted.** ⛔ *An arm that cannot reach its own state is arm 10's defect and
   is the round's most valuable output.*
4. **Each precondition sits ADJACENT to the act it guards**, not at the top or
   the end of its test.
5. **Both files still pass otherwise**, and the suite is green.
6. **PER-FILE counts AND the suite total.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒ `NodeIdentity.signing_context/0` fails and no
node-signed write succeeds. ⭐ **Use fixture signing contexts via
`opts[:signing_context]`.** ⚠️ **Do NOT widen a verification function's accepted
options to make an arm reachable — `SlaTombstone.verify` accepts only `:store`
and that is deliberate. If an arm needs more, that is a finding.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main
baseline, WITH ITS STATE STAMP — the stamp is part of the number:**
```
  5 doctests, 3521 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  sha:        be3d57bf (clean vs HEAD)
  test state: DIRTY — tmp/test_data/root present (written 2026-04-27)
  deps:       repo deps/     cwd: /home/jes/commonplace/apps/commonplace
```
⚠️ **BUILD FROM THE BASE THIS BRIEF IS ADDED IN.** ⭐ **A suite total without its
state stamp is not a baseline — a run in a DIFFERENT state may legitimately
differ, and that is a scope difference to investigate, not a round being wrong.**

### ⛔ TWO KNOWN-NONDETERMINISTIC TESTS — proven on a CLEAN tree, NOT yours

**Both reproduce on an unmodified tree via `--repeat-until-failure`:**
```
GitBridge.ServerTest  "pause/resume: paused sync_now …"   rep 13  GenServer.stop → no process
DeniedWriteReportingTest "parent-schema registration …"   rep  5  assert landed_count == 4
                                                                  left: 5  right: 4
```
⚠️ **`DeniedWriteReportingTest`'s write count is NONDETERMINISTIC (observed 4 and
5) — `CX-7rjn`. It can also fail as a MatchError on
`Schema.get_entry(dir_schema, Schemas.issue_filename())` returning `:error`;
BOTH shapes are the same root.** ⛔ **If you see either, it is NOT yours — but
say which you saw, verbatim.**
⚠️⚠️ **THE LEAK DETECTOR'S NUMBER IS NOT A BASELINE — it has read
`0 · 58 · 68 · 72 · 115 · 117 · 118 · 122 · 127 · 149 · 152` across populations
and the movement is UNATTRIBUTED. A different number is EXPECTED and is not a
regression.** ⛔ **If it appears as a FAILURE rather than `ADVISORY`, that is a
finding.**
⚠️ **Known reds by TEST and MECHANISM:** `CX-kx6d` — `GitBridge.ServerTest`
*"filters: __ / nosync / presence … across two cycles"*, teardown check-then-act;
**unticketed** — `GitBridge.ServerTest` *"push: … unreachable remote … retries"*,
`{:error, :already_registered}` from `WorkspaceFixture.complete_workspace!/2`;
`CX-s9kc` — `chat_view_compute_supervisor_test.exs`. ⛔ **ANY OTHER failure, or
these with a DIFFERENT error shape, IS YOURS — say which you saw, verbatim.**
⚠️ *And a stray tmux socket has once triggered the launcher's channel-isolation
test; check for incidental sockets before treating that one as yours.*

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES** —
  starting with the count above.
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to adjust an arm that
  fails its new precondition, or to place a precondition where it is convenient
  rather than where the act happens.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

A precondition on every negative arm in both files, each adjacent to the act it
guards; the per-arm table showing which arms already had one; any arm failing its
new precondition reported rather than adjusted; the count re-derived from the
stated pattern with discrepancies reported; both files green; per-file counts and
the suite total.
