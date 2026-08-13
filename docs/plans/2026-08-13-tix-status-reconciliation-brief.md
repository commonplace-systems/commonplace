# Build brief: the tix status reconciliation pass

> **Why this round exists, and it is not bookkeeping.** The ranking
> instrument is **measurably wrong in both directions**, and three
> rankings in one hour were made on it before anyone noticed:
> S33 was ranked for dispatch **18 hours after it closed**; CX-v14m was
> carried all day as "a decision, not work" while **its security half had
> already been fixed**; and plan named **ten p1s it believes shipped and
> are still open**.
>
> ⭐ **INSTRUMENTS OUTRANK INVESTIGATIONS. Every future ranking is wrong
> until this runs.**
>
> ⛔⛔ **THE ROUND'S ONE HARD RULE, PLAN'S, BINDING: CLOSE FROM EVIDENCE,
> NEVER FROM A TITLE MATCH.** ⚠️ **The ten names below are CLAIMS TO
> VERIFY, not a close list.** They were derived from memory — **the
> instrument that just failed three times.**

## What you are producing

**A verdict table with evidence per row.** ⛔ **NOT a count of closures,
and NOT any ticket writes** — the tix verbs are unreachable from the
sandbox (**a capability boundary, not a defect**). The reviewer executes
every write; **your table is the input to that, and it is the whole
deliverable.**

Land it at **`docs/notes/2026-08-13-tix-status-reconciliation.md`**.

| column | content |
|---|---|
| ticket | `CX-xxxx` |
| verdict | `CLOSE` · `STAY-OPEN` · `UNVERIFIABLE` · `DUPLICATE-OF` · `CLEAR-CLAIM` |
| the ticket's stated condition | **in its own words**, one line — what would have to be true |
| evidence | a **SHA**, a **path:line**, or a **test name** — something a reader can open |
| what you checked | including what you looked for and did **not** find |

## ⛔ What counts as evidence, and what does not

⭐⭐ **A COMMIT MENTIONING `CX-xxxx` PROVES INTENT WAS ADDRESSED. IT DOES
NOT PROVE THE TICKET'S STATED CONDITION IS MET.** ⇒ Read the condition
first, **then** go find the artifact that satisfies **that**.

- ✅ **Evidence**: the code at a named path implements the described
  behaviour · a test exists **and runs** that asserts it · a commit whose
  **content** (not subject) does the thing · a doc that records the
  ruling the ticket asked for.
- ⛔ **NOT evidence**: a commit subject naming the id · a plan/brief that
  *describes* the work · a title that "sounds done" · a ticket referenced
  in another ticket's close reason · **your own recollection.**
- ⭐ **The worked example this round exists because of:** S33's commit
  subject said S33, **and the round really had shipped** — but that was
  established by opening the artifact and confirming its **three named
  conditions** (refuse-at-birth field-named, `authors_code → w+x`, the
  pair landing as one change with `File.ln/2` present at **both** sites).
  ⇒ **The subject was consistent with both "done" and "started". Only the
  artifact separated them.**

## ⭐⭐ `UNVERIFIABLE` IS AN HONEST OUTCOME AND YOU ARE EXPECTED TO USE IT

⛔ **A ticket that cannot be verified either way STAYS OPEN and SAYS
SO.** ⇒ *"Unverifiable from the artifact"* + what you would have needed
**is a better row than a confident close.** ⚠️ **A reconciliation pass
that closes on weak evidence re-commits the original defect at scale and
closes live work** — the failure mode here is not missing a closure, it
is **manufacturing one.**

## The 43 targets

Bodies exported from tix and copied in as **`tix-reconcile-targets.md`**
(82 KB, at the worktree root). ⚠️ **3 of the 43 have NO description —
report which**; a ticket whose whole content is its title is itself a
finding.

**① The ten plan believes shipped** — `CX-vvbh` · `CX-q9sa` · `CX-1jh2` ·
`CX-b38c` · `CX-fm7x` · `CX-5gkw` · `CX-e2vk` · `CX-evy4` · `CX-s4wh` ·
`CX-vm8m`. ⚠️ **The last four are an arc** whose questions plan believes
were *answered* by the phase-a/phase-b pipeline — **an answered question
and a fixed bug close differently; say which each is.**

**② The 28 `in_progress` with nothing running.** ⭐ **Different question:
not "is it done" but "is anyone on it."** A stale claim on unfinished
work is `CLEAR-CLAIM` (**stays open, claim dropped**), not `CLOSE`.
⛔ **Do not close a ticket merely because its claim is stale.**

**③ The four anomalies**, each of which distorts ranking on its own:
- `CX-895n`, `CX-wqt2` — titled **"START HERE 2026-08-10"**, open p1,
  pointing at a morning three days gone. **A pointer ticket cannot age
  well**; verdict on whether anything in them is still live.
- `CX-96t5` — titled **"⛔ RETRACTED — NOT ESTABLISHED"**, open at p1.
  ⇒ **A retraction that stays open ranks as work.**
- `CX-d81c` / `CX-tq3f` — **identical titles.** Confirm true duplicate
  and say **which id survives** (⭐ prefer the one with history:
  references, needs-edges, the longer body).

## Tools you have and don't

- ✅ `git log --all --grep=CX-xxxx`, `git show`, the full worktree, the
  test suite.
- ⛔ **No tix, no serve, no live store** — reachable only by the
  reviewer.
- ⚠️ **A worktree cannot host a suite run** (no `deps/`, no `_build/`);
  compile through writable copies as usual. **You should not need the
  suite** — if you do, say why.

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended
  commit message**.
- ⛔ **No production code changes this round.** If verifying a ticket
  reveals a live defect, **that is a FINDING to report, not a fix to
  make.**
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If you cannot find this brief or `tix-reconcile-targets.md`, STOP
  AND SAY SO** rather than reconstructing the target list.
- ⛔ **If a fenced capability is needed, NAME IT** rather than working
  around its absence.
- ⭐ **Report the NEAR-MISS** — any ticket you were tempted to close on
  a subject line, a plausible title, or a brief that described the work.
  **State it even if you did not act on it.**
- ⭐ **Report a MEASUREMENT, never a mechanism you did not observe.**

## Review criteria

Every row carries an openable artifact or says `UNVERIFIABLE` with what
was missing; no row closed on a subject line; `in_progress` rows
distinguish *done* from *unclaimed*; the duplicate names a survivor with
a reason; the three body-less tickets are named; no production changes;
the file lands in the tree.
