# Measure what `CX-7rjn` is actually detecting — the count, or the enforcement boundary

> **Ruled by `commonplace-plan`.** Base: **the commit that adds this brief** —
> ⚠️ *not a sha.* **Build the worktree from that base.**
>
> ⛔ **THIS ROUND MEASURES. IT DOES NOT REPAIR.** *A gate is held open pending its
> result; changing the subject would answer nothing.*

## The question, and why the obvious version of it is the wrong one

**`DeniedWriteReportingTest`'s test *"parent-schema registration reports denial
for an existing indexed issue directory"* fails intermittently on a clean tree
with:**
```
assert landed_count == 4
left:  5     right: 4
```

**The obvious reading is "the write count is nondeterministic." A source read
suggests otherwise — the create path looks FIXED at five:**
```
build_issue_dir     create_text_doc_checked(issue_json)      1
                    create_text_doc_checked(description)     2
                    create_dir_with_meta(comments)           3
                    create_commit(dir_uuid, …)               4
add_issue_entry     create_chained_commit(issues_uuid, …)    5   ← parent-schema write
```
⇒ ⭐ **And that explains the test's DESIGN: it fires `enforce_unsigned_denials!()`
at count 4 so THE FIFTH WRITE — the parent-schema registration — is the refused
one. That is literally the test's name.**

⇒ ⛔⛔ **SO `landed_count == 5` MAY MEAN THE ENFORCEMENT BOUNDARY MOVED, NOT THE
WRITE COUNT.** ⭐ ***The count was only ever a PROXY for when enforcement took
effect.***

⚠️⚠️ **THE ABOVE IS A SOURCE READ AND IT IS THIS BRIEF'S HYPOTHESIS, NOT ITS
PREMISE.** ⛔ **`READ < RUN < PERTURB`. In the last day a source read said an arm
was "unsatisfiable" and a rehearsal refuted it; another said "the count did not
move" and the count moved.** ⇒ ⭐ **MEASURE. Report what you observe even if it
matches NONE of the branches below.**

## ⛔ What to build — instrumentation, not a fix

**Instrument the failing test so that at EACH write it records:**
1. **the write ordinal** (the counter the test already keeps), and
2. ⭐ **BOTH knob values at that moment** — `Application.get_env(:commonplace,
   :trust)` and `Application.get_env(:commonplace, :local_write_gate)`.

**Then run it until it fails, capturing the full record.** ⭐ **Use
`--repeat-until-failure`, and note its limit: it REUSES ONE BEAM, so a
first-run/startup condition is invisible to it. If it will not fail in-process,
run fresh processes in a loop.**

⛔⛔ **REDIRECT OUTPUT TO A FILE AND READ THE FILE. A transient gives you exactly
one chance at its artifact** — *the summary line is the one part of a test run
that cannot say what broke, and this round exists because that artifact was
destroyed once already.*

## ⭐ The two branches — and the third is already closed

```
(a) the count genuinely varies                    ⇒ CX-7rjn is a test cleanup
(b) the count is fixed at 5, and at write 5 the
    two knobs are HALF-SET                        ⇒ a FIXTURE ATOMICITY bug
```
**`enforce_unsigned_denials!` sets `:trust` and THEN `:local_write_gate` — two
sequential `put_env` calls, executed INSIDE A TELEMETRY HANDLER during write 4.**
⇒ **If write 5 arrives with one knob flipped and the other not, that is (b).**

⛔ **DO NOT HUNT A PRODUCTION ENFORCEMENT WINDOW — IT IS ALREADY RULED OUT.**
**Enumerated across all apps, every `Application.put_env` in lib code targets:**
`:mud_engine_manifest` · `:safe_verb_profile` · `:data_dir` ·
`:workspace_lock_on_boot` · `:reflog_on_boot` · `:mud_full_citizenship` ·
`:flock_nif_path`. ⇒ **NONE touches `:trust` or `:local_write_gate`.** *(Positive
control: the literal pattern IS findable in test files, so that zero is an
absence and not a broken query.)*
⇒ ⭐ **So production never flips enforcement live, and branch (b) is a FIXTURE
bug, not a trust-surface finding.** ⚠️ **Named residual, recorded and NOT part of
this round: a serve RESTART changes both knobs, and config providers /
release-time live-reload are UNAUDITED. A restart is not a live transition and
nothing is mid-write across it.**

## ⛔ Why this round exists — the decision it unblocks

**`CX-7rjn` selects both its trigger and its target by ORDINAL. The repair is
gated on this measurement:**
```
(a)  ⇒ repairing the ordinal is a clean test fix.
(b)  ⇒ the ordinal is unintentionally measuring ENFORCEMENT LATENCY,
       and repairing it DELETES THE ONLY THING THAT EVER NOTICED.
```
⭐ ***That is the entire reason the gate is shut. Do not repair anything.***

## ⛔ Acceptance — artifacts

1. ⭐⭐ **A captured failing run showing, per write: the ordinal AND both knob
   values.** *Verbatim, from a file.*
2. ⭐ **A captured PASSING run of the same instrumentation**, so the failing
   record can be compared against the normal one. ⚠️ *A record with nothing to
   compare it to cannot show which value is anomalous.*
3. ⭐⭐ **The branch named — (a), (b), or NEITHER — with the observation that
   decides it quoted directly.** ⛔ *If it matches neither, say so; that is a
   publishable result and more valuable than forcing a fit.*
4. **How many runs it took to reproduce, and in which harness** (in-process
   repeat vs fresh processes). ⚠️ *A reproduction count is part of the finding.*
5. ⛔ **NO REPAIR. No ordinal changed, no assertion adjusted, no fixture made
   atomic.** *If you see the fix, describe it in the report and leave the code
   alone.*
6. **PER-FILE counts AND the suite total from the tool's own block, plus the
   POPULATION DELTA BY HAND** — the stamp uses `--untracked-files=no` and is
   blind to a new untracked test file.

## ⚠️ IF IT WILL NOT REPRODUCE

⭐ **That is a publishable result, not a failure — SAY SO, with the run count and
harnesses tried.** ⛔ **Do NOT conclude it is flake and do NOT conclude it is
fixed.** ⚠️ ***A nondeterministic mechanism exonerates itself in any given run,
and a reproducer that has never gone red has no negative to offer.***
*Known: it has been reproduced at repetition 5 of a fresh-process run of that
file alone, and 21 later runs across three harnesses did not reproduce it.*

## ⭐ RIDER — one file, mechanical, do it wherever it is cheapest

**`apps/commonplace/test/commonplace/identity/root_scope_gate_test.exs` mints a
capability and stores it (measured: 1 `Capability.issue`, 1 `store_capability`,
17 asserts) and NEVER drives it through a production gate (measured: 0 gate
calls, 0 `verify_chain`).** ⇒ **Same gap S89 closed in its two siblings, which
were copied FROM this file.**

⛔⛔ **DO NOT INVENT THE ARMS — COPY THEM FROM `apps/commonplace/test/commonplace/
trust/subtree_carve_test.exs`, WHICH IS THE CHAIN'S ROOT AND IS CLEAN** (measured:
6 gate calls, 2 chain verifications). ⇒ ⭐ ***The defect entered at the FIRST COPY,
not the template: this file was modelled on a CORRECT original and dropped the
gate-driving.*** **The original is the reference implementation.**

⚠️ **`runner/deployment_record_test.exs` is DELIBERATELY EXCLUDED: it mints ZERO
capabilities, so its zero gate-calls is CORRECT, not a gap.** ⛔ **Do not add gate
arms there.** ⭐ *A zero is only a gap if the thing it would measure is present.*

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` fails. ⭐ **Use fixture
signing contexts via `opts[:signing_context]`.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **Baseline
pasted verbatim as measured — NOT retyped to match your base:**
```
  5 doctests, 3528 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  sha:        99acc5d1 (DIRTY — 5 tracked file(s) modified vs HEAD)
  test state: DIRTY — tmp/test_data/root present (written 2026-04-27)
  deps:       repo deps/   cwd: /home/jes/commonplace/apps/commonplace
```
⚠️ **Those 5 modified files were S88, landed as `f27abab5`. A later round may have
raised the count — report YOUR block and the delta, do not reconcile to this one.**
⚠️⚠️ **THE LEAK DETECTOR'S OBSERVED VALUES ARE A RECORD, NOT A BOUND.** Seen so
far: `0 · 58 · 68 · 72 · 115 · 117 · 118 · 122 · 123 · 126 · 127 · 135 · 141 ·
149 · 152`. ⛔ **That is a list of numbers we happen to have seen, NOT a range.**
⇒ ⭐ **A value outside it is NOT an anomaly and NOT a finding — do not report a
new number as a discrepancy.** *Read as a range, the format MANUFACTURES the
anomaly.* ⛔ **Only `FAILURE` rather than `ADVISORY` is a finding.**

### ⚠️ Known-nondeterministic, by TEST and MECHANISM — NOT yours

```
GitBridge.ServerTest      GenServer.stop → "no process" in on_exit. MODULE-WIDE:
                          "filters: __ / nosync / presence", "phantom-diff pin",
                          "pause/resume". Reproduced on a clean tree.
chat_view_compute_supervisor_test.exs    CX-s9kc.
```
⛔ **`DeniedWriteReportingTest` IS THIS ROUND'S SUBJECT — its failure is what you
are hunting, not a known-red to excuse.**
⚠️ **One UNATTRIBUTED observation: a single directory-level run of
`test/commonplace/trust/` once reported `244 tests, 1 failure`; the artifact was
destroyed and the test is UNKNOWN. 21 later runs did not reproduce it. NOT an
acquittal. If you see a red there, CAPTURE THE FULL OUTPUT FIRST.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION** — **especially its five-write
  reading, which is a SOURCE READ.** ⛔ **REPORT DISCREPANCIES.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to fix what you measure,
  or to call an unreproduced failure flake.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

A captured failing record showing ordinal plus both knob values per write; a
passing record to compare against; the branch named with its deciding
observation quoted, or an honest "neither"; the reproduction count and harness;
no repair of any kind; per-file counts, suite total, and the population delta by
hand.
