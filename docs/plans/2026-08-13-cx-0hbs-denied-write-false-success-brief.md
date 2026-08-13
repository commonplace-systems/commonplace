# CX-0hbs build brief: a denied write must tell the caller it was denied

> **The work's tickets are CX-0hbs and CX-9wy4**, ruled ONE ROUND by plan,
> ranked **#1** by commonplace-plan and
> pre-empting everything else. Base: **`db0505a7`** on `main`.
>
> ⛔⛔ **THE FIRING CONDITION IS LIVE RIGHT NOW.** Measured on the running
> serve by two parties with two instruments: **`local_write_gate: :enforce`,
> `accept_unsigned: false`.** This is not a latent defect awaiting a config
> change.
>
> ⭐ **Plan's basis for the rank, and it is the frame to keep: THE GATE IS
> WORKING CORRECTLY — that is what makes it expensive.** The refusal is the
> safety mechanism doing its job. **The defect is that the refusal is
> invisible to the caller**, so ⇒ **protection + silence = DATA LOSS WITH A
> SUCCESS RECEIPT.** Every downstream party has already been told the
> opposite of the truth.

## The defect, exactly — FIVE sites across TWO modules

⛔⛔ **PLAN'S SCOPE RULING, 2026-08-13, and it corrects an earlier fence of
its own: "I FENCED AGAINST MECHANISM CREEP, NOT AGAINST COVERAGE OF THE SAME
MECHANISM."** *Small and forbidden from growing* meant **no rescue, no retry,
no queue, no new semantics** — it did **NOT** mean *only the sites known when
it was ruled*.
⇒ ⭐ **Fixing one instance while a known-identical instance stays live is not
a smaller change — it is a PARTIAL FIX TO A SILENT-LOSS CLASS, and those are
worse than no fix BECAUSE THE FIRST FIX'S SUCCESS MAKES EVERYONE BELIEVE THE
CLASS IS CLOSED.**

| file | line | branch | replies |
|---|---|---|---|
| `command_router.ex` | **`:443`** | diff-write | `{:ok, audit, audit}` |
| `command_router.ex` | **`:471`** | forced-clobber (`force: true`) | `{:ok, …}` |
| `command_router.ex` | **`:526`** | set-sync | `{:ok, …}` |
| `bd/issue.ex` | **`:347`** | issue-dir `create_commit` | `dir_uuid` |
| `bd/issue.ex` | ⛔ **`:422`** | **issue-dir registration in the parent schema** | `:ok` |

**All five call `CommitStoreClient.create_commit/create_chained_commit` with
the return value NEITHER BOUND NOR MATCHED**, then reply success
unconditionally.

⛔⛔ **`:422` IS THE WORST OF THE FIVE AND IS TOP-OF-ROUND: it registers a new
issue's directory in the PARENT SCHEMA.** ⇒ **A denied write yields A TICKET
THAT EXISTS, REPORTS CREATED, AND APPEARS IN NO LISTING** — the CX-0mns
invisible-ticket class arriving through a second, unrelated hole.
⭐ **And the multiplier is why it outranks the other four: A SILENTLY-LOST
CLOSE READS AS AN OPEN ROW FOREVER; A SILENTLY-LOST CREATE READS AS WORK
NOBODY FILED.** ⇒ **The defect does not merely lose data — IT CORRUPTS THE
INSTRUMENT USED TO DECIDE WHAT TO DO NEXT.**

⇒ When the gate denies, the call returns `{:error, {:trust_rejected, …}}`,
**the handler replies success, and the head is unchanged.**

⚠️ **The count is the fence, and it has re-proved itself twice: filed as ONE
site, measured as THREE, now FIVE across two modules.** ⛔ *A fix that binds some sites and
leaves the rest is the failure mode this brief exists to prevent* — an
earlier version of this instruction said "the class in that module, not one
line" and **a principle-shaped fence gets satisfied narrowly.**
⇒ **FIVE line numbers, named. Check for a sixth, in both modules.**

## Reachability — why this is p1 and not p3

`CommandRouter.write/2..4` is called from **five live paths**:

- ⭐ **`apps/commonplace_mcp/lib/commonplace_mcp/tools/write.ex:45`** — **the
  MCP write tool. Agents are being told their own writes landed.**
- `apps/commonplace/lib/commonplace/chat/rooms.ex:218`
- `apps/commonplace/lib/commonplace/view_compute.ex:427`
- `apps/commonplace/lib/commonplace/black/pattern_compute.ex:358`
- `apps/commonplace/lib/commonplace/smart_doc.ex:110`

## ⛔ The fix, ruled small and forbidden from growing

**Bind and match the return at all FIVE sites. A denial becomes a NAMED
ERROR to the caller.**

- ⛔ **NOT a rescue. NOT a retry. NOT a queue.** ⇒ **The caller learns it
  failed, and why.** *Anything that makes the write eventually succeed is a
  different ticket and a much larger one.*
- ⛔ **Do not weaken, bypass, or "handle" the gate.** The denial is correct
  behaviour; only the reporting is wrong.
- ⚠️ **Preserve each branch's existing success shape.** The five sites return
  DIFFERENT success values — `{:ok, audit, audit}`, `{:ok, %{…}}`, a bare
  `dir_uuid`, and `:ok`. **Match what each already returns on the happy
  path**; ⛔ *normalising them into one shape is a redesign, not this fix.*

## ⭐ Acceptance — red-first, and the red is the current behaviour

1. ⭐⭐ **RED FIRST, AND IT IS UNUSUALLY EASY HERE BECAUSE THE BUG IS THE
   CURRENT BEHAVIOUR: with an ENFORCING fixture store, a write through
   `CommandRouter.write` that the gate denies TODAY returns a SUCCESS while
   the write is ABSENT from the store.** ⇒ **Assert both halves — the `:ok`
   reply AND the absent write — before the fix. Report that output
   verbatim.** *A red that only shows the reply proves half of it.*
2. **After the fix: the same write returns an error naming the refusal.**
3. ⛔⛔ **A CONTROL THAT GOES RED IN BOTH DIRECTIONS: a PERMITTED write must
   still return its normal success.** ⇒ *The cheapest wrong fix is to
   propagate so faithfully that every write becomes a failure, and arm 2
   alone cannot detect it.*
4. **All FIVE sites exercised, both modules.** ⚠️ *One test proves one
   binding.*
5. ⭐⭐ **REQUIRED ARM, PROMOTED FROM AN OPEN QUESTION BY PLAN — ANSWER IT:
   DOES THE S24/S25 CREATE-TIME ISSUE-DOC INDEX DETECT A TICKET ORPHANED BY
   A DENIED `:422` WRITE, OR IS THE INDEX WRITE ITSELF UNBOUND?** ⇒ **If it is
   also unbound, then the instrument built to catch invisible tickets is
   invisible-ticket-generating under the same condition** — a detector that
   cannot see the failure mode it exists for. ⭐ **Either answer is
   publishable; "the index is also unbound" is the finding that matters
   most.**
6. ⭐ **TICKET WRITES USE A LINKAGE CONTROL, NOW THE STANDARD: check EXISTENCE
   and LINKAGE SEPARATELY** — `Bd.Issue.show/3` **succeeds on exactly the
   orphan this describes**, so a re-read that cannot distinguish *created*
   from *created and findable* is a re-read that would have passed the bug.
   ⚠️ **And if you enumerate to prove linkage, DO NOT DIFF AGAINST A PAGINATED
   LIST** — a truncated listing manufactures false orphans **indistinguishable
   from real ones** (measured today on a sibling tool: a known-good ticket was
   *also* missing, and a corpus count of exactly the page size was the tell).
   ⭐ **Better: reconstruct from the parent schema's registered directories and
   compare against the ticket docs that exist — that comparison cannot be
   truncated into a false alarm, and it answers *is this doc registered?*
   rather than a proxy for it.**
7. **Tests LAND AS FILES with each file's own count from the tree.**

## Suites — and a required field

Baseline, **a falsifiable claim; measure your own and report it**: core
**3,472 / 0 failures / 1 skipped** @`db0505a7` **at seed 117514**.
⛔⛔ **REPORT THE SEED OF EVERY SUITE RUN YOU DO.** ⚠️ **Two runs that differ
in code AND order are not a comparison** — this was established today at the
cost of three full suite runs.
⚠️ **Known: `--seed 16421` reproduces two UNRELATED failures on this tree
(`CX-g9ea`)** — `MUD.RoomVisibilityTest:372` and a `Trust.ReadTest` teardown
race. ⛔ **They are NOT yours.** ⭐ **But if the MUD one DISAPPEARS after
your fix, SAY SO LOUDLY — plan ruled that your fix is the discriminator for
whether `CX-0hbs` was causing it.** *"(this place has no description)" is
exactly what a silently-failed description write renders as.*
⛔ **Never pipe a long `mix test` — redirect to a file.**

## Files

- **MAY touch**: `apps/commonplace/lib/commonplace/command_router.ex` ·
  `apps/commonplace/lib/commonplace/bd/issue.ex` · their tests.
- ⛔ **MUST NOT change**, verified present at this base:
  `run_recipe.ex` (md5 `230839fc23e1047282306486ea48db41`) ·
  `run_recipe_test.exs` (md5 `07c92ded3ac4668225fdff5eb3482602`) ·
  `trust/audit_log.ex` (CX-8fyq landed yesterday — **do not re-shape the
  writer field**).
- ⛔ **`sol-egress-run.sh` is never edited from inside a round.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended commit
  message**.
- ⛔ **No live-store contact.** The store path is workspace-relative
  (`workspace/.commonplace/commits/`), **not** repo-root, **not** `data/`.
  ⚠️ **A live reproduction is explicitly NOT wanted** — it would mean
  issuing a real write against the live world to watch it fail.
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** If the line numbers, the
  branch descriptions, or the count of three do not match the artifact,
  ⛔ **report the discrepancy rather than satisfying the claim.** ⚠️ *A
  builder's refusal has caught a wrong brief-fact three times this week.*
- ⭐ **Report a MEASUREMENT, never a mechanism you did not observe** — and
  **name any failure's SUBJECT as `file:line`.**
- ⭐ **Report the NEAR-MISS**, especially anything that tempted you toward a
  retry, a rescue, or touching the gate.

## Review criteria

All FIVE sites bind and match; a denied write returns a named error and a
permitted write still succeeds, **both demonstrated**; the red was shown
first with the success-reply AND the absent write; no retry/rescue/queue; no
gate change; seeds reported; counts reconciled against a self-measured
baseline.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not reachable
from inside the sandbox — **a capability boundary, not a defect.** Report
identities; the reviewer files them.
