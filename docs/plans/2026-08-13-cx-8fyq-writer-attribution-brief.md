# CX-8fyq build brief: a denial must name WHO ASKED, not only what was refused

> **The work's ticket is CX-8fyq**, retitled today to stop over-claiming:
> *"part 1 SHIPPED (process attribution, `47e5d2d0`); the WRITER-attribution
> half remains."* Base: **`b1278e7f`** on `main`.
>
> ⭐ **The ticket's own rule, and it is the reason this is p1: A GATE THAT
> RECORDS ONLY WHAT IT REFUSED, AND NOT WHO ASKED, PRODUCES A CORPUS YOU
> CAN COUNT BUT CANNOT ACT ON.** ⚠️ *Counting is the part that feels like
> measurement.*
>
> ⛔ **It is not theoretical — it already produced two wrong numbers that
> two careful parties carried**: *"the Bursar is 90% of all denials"* (the
> Bursar is not visible in the corpus at all) and *"134,507 denials"* (the
> live counter said 155). **Both survived because a number about denials
> had no way to be checked against a writer.**

## What part 1 did, and why it is not this

`47e5d2d0` added **`firing_process`** — *which process emitted the event*.
⚠️ **That is the telemetry handler's own process**: the denial fires from
inside `CommitStore.handle_call`, so `firing_process` is essentially always
the CommitStore. ⇒ **It says where the refusal was recorded, not who
attempted the write.**

## The asymmetry that makes this small

Two payload builders in **one file**:

| builder | line | carries a principal? |
|---|---|---|
| `local_write` (the highest-volume gate) | `audit_log.ex:302-318` | ⛔ **no** |
| the generic gate record | `audit_log.ex:356` | ✅ `"principal" => metadata[:principal] \|\| metadata[:peer]` |

⇒ **The field exists, the schema supports it, and the gate that omits it is
the one that produces the corpus.**
⚠️ And on the dominant denial class the one identity field present is
useless by construction: **`signer_id_claimed` is nil for every `:unsigned`
denial BY DEFINITION** — an unsigned write claims no signer.

## What to build

**Carry a writer identity from the callsite into the local_write denial
metadata, into the audit record, and into the log line.**
`create_chained_commit/5` already takes `opts`; ⭐ **the callsite is the
only place that knows.** The ticket's stated minimum is **module + function
of the writer**.

- ⛔⛔ **DO NOT INFER THE WRITER FROM `doc_uuid`.** That inference is
  precisely what produced the Bursar mis-attribution — **it was the only
  one available, and it was wrong.** An inferred writer is worse than an
  absent one, because it is actionable and false.
- ⭐⭐ **AN ABSENT WRITER MUST BE DISTINGUISHABLE FROM A NAMED ONE, AND
  BOTH FROM A CALLSITE THAT NEVER PASSED IT.** ⇒ Decide and **state** how
  the record represents *"this callsite did not say"* — ⛔ **silently
  omitting the key rebuilds today's blindness in a new field.** *This is
  the round's one real design decision; make it deliberately and say why.*
- ⚠️ **You do not have to convert every callsite.** Converting the ones
  that produce real denials is enough for the acceptance below — **but
  report which callsites you threaded and which you left**, because an
  unconverted callsite is exactly the silent-absence case above.

## ⭐ Acceptance — the ticket's own, and arm 2 is the deliverable

1. **A denial record names its writer** — demonstrated on a **REAL denial**
   your test provokes, with **the record pasted verbatim**.
2. ⭐⭐ **THE CONTROL MUST BE ABLE TO GO RED: provoke denials from TWO
   DIFFERENT WRITERS and show the records DIFFER in that field.** ⛔ **One
   writer proves nothing — a hardcoded constant passes that test.** *This
   arm is the difference between a field that is populated and a field
   that is correct.*
3. ⚠️ **"Re-run the corpus grouping and show non-canary denials
   attributed" is a LIVE-SERVE criterion and is NOT VERIFIABLE IN YOUR
   SANDBOX.** ⇒ **Report it as UNVERIFIED and stop there.** The reviewer
   runs it outside, read-only. ⛔ **Do not simulate it and do not reach for
   the live store** — the store path is workspace-relative
   (`workspace/.commonplace/commits/`), **not** repo-root, **not** `data/`.

- **Tests LAND AS FILES with each file's own count from the tree.** An
  existing file is a fine home — *exists AND executes* is the property.

## Files

- **MAY touch**: `apps/commonplace/lib/commonplace/trust/audit_log.ex` ·
  `apps/commonplace/lib/commonplace/store/commit_store.ex` (the denial
  emission + `create_chained_commit` opts) · callsites you thread ·
  their tests.
- ⛔ **MUST NOT change**: the **import**/`trust` gate payload (a different
  gate, out of scope) · `run_recipe.ex`
  (md5 `230839fc23e1047282306486ea48db41`) ·
  `run_recipe_test.exs` (md5 `07c92ded3ac4668225fdff5eb3482602`).
  ⚠️ **All three exist at this base — verified.**
- ⛔ **`sol-egress-run.sh` is never edited from inside a round.**

## Tests

Baseline, a **falsifiable claim — measure your own and report any
difference**: core **3,471 / 0 failures / 1 skipped** @`b1278e7f`.
⚠️ **Run per-app**; multi-app `mix test` paths silently drop tests here.
⚠️ **A worktree cannot host a suite run** (no `deps/`, no `_build/`).
⛔ **Never pipe a long `mix test` to anything — redirect to a file.** *A
pipe adds a second process that can hang after the first has said
everything useful: one run yesterday printed a COMPLETE green and exited
rc 130.*

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended
  commit message**.
- ⛔ **Do not run `mix format` or `mix precommit`.** Use
  `--check-formatted`.
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⛔ **If a fenced capability is needed, NAME IT.** **A `0` from a probe
  may mean MASKED, not ABSENT** — and *"blocked"* and *"not there"* share
  an exit code, which is this ticket's own defect one layer up.
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** If a line number, a
  payload shape, or the part-1 characterisation does not match the
  artifact, ⛔ **report the discrepancy rather than satisfying the claim.**
- ⭐ **Report the NEAR-MISS** — especially anything that tempted you to
  infer the writer rather than be told it.
- ⭐ **Report a MEASUREMENT, never a mechanism you did not observe.**

## Review criteria

A real denial record carries a writer; **two different writers produce
different values**, demonstrated; absence is represented deliberately and
explained; no inference from `doc_uuid`; the live-corpus arm reported
UNVERIFIED rather than simulated; threaded and unthreaded callsites both
named; core suite reconciled per-app against its own measured baseline.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — **a capability boundary, not a
defect.** Report identities; the reviewer files them.
