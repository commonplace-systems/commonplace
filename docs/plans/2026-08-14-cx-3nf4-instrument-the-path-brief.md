# CX-3nf4 build brief: INSTRUMENT the path — three layers were read and all were correct

> **The work's ticket is CX-3nf4.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## ⛔⛔⛔ DO NOT BRIEF-CHASE A LOCUS. THREE HAVE BEEN READ AND CLEARED.

**A write reports success and lands nothing:**

```
$ commonplace_cli bd create --title "…"
  Created CX-mzkq        rc=0        ← SUCCESS RECEIPT, EXIT ZERO
  Bd.Issue.show(…)  →  {:error, :not_found}
  973 issues listed, CX-mzkq absent  (positive control: a ticket filed via erpc that
                                      night IS present, so the list is the right instrument)
```

⛔ **ALREADY READ AND FOUND CORRECT — DO NOT RE-READ THESE:**

| # | layer | what it does |
|---|---|---|
| ① | CLI `cmd_create` | `case Issue.create(...) do {:error, reason} -> error_exit(...)` ✅ |
| ② | `Issue.create` → `build_issue_dir` | `create_text_doc_checked` ×2; commit via `case {:error,_} -> {:error,_}` ✅ |
| ② | `Issue.create` → `add_issue_entry` | `case create_chained_commit ... {:error, reason} -> {:error, reason}` ✅ |
| ③ | `CommitStoreClient.create_commit` | remote branch is a bare `GenServer.call` returning the serve's answer ✅ |

⇒ ⭐⭐ **EVERY LAYER READ WAS CORRECT AND THE DEFECT REPRODUCES.** ⛔ ***A bug
that survives three correct layers will not be found by reading a fourth.***

⚠️ **AND THE REVIEWER GOT THIS WRONG THREE TIMES IN A ROW BY THE SAME METHOD:
each correction read the layer the previous finding named.** ⇒ ⭐ ***Following
your own pointer is not independent evidence — it is the same guess one frame
deeper.*** **That is why three attempts felt like three investigations and were
one.**

## ⭐ What to do instead: OBSERVE WHAT EACH LAYER RETURNS

**Run the reproduction with instrumentation and record the ACTUAL return value at
each hop** — not what the source says it returns.

⭐ **The question is precise: WHERE DOES `{:ok, …}` FIRST APPEAR FOR A WRITE THAT
DID NOT LAND?** ⇒ **Everything above that point is innocent; everything below it
is already cleared.**

## ⭐⭐ YOUR SANDBOX IS AN ADVANTAGE HERE, FOR ONCE

**Standing property: `node_signing_key` is masked, so
`NodeIdentity.signing_context/0` FAILS and no node-signed write can succeed in
there.** ⚠️ *Normally that makes a green suspect.* ⇒ ⭐ **HERE IT MEANS REFUSED
WRITES ARE THE DEFAULT, which is exactly the condition under test.**

⇒ **So build a LOCAL fixture workspace and reproduce without any serve:**

```
a fresh workspace under /tmp (commonplace init)
COMMONPLACE_LOCAL_WRITE_GATE=enforce
attempt a bd create
observe: does it print an id? does the ticket then exist?
```

⛔ **DO NOT TOUCH THE LIVE SERVE OR THE LIVE STORE.**
*Live store: `/home/jes/commonplace/workspace/.commonplace/commits/` —
workspace-relative, NOT repo-root, NOT `data/`.* ⚠️ **The reviewer's
reproduction went through the live serve; YOURS MUST NOT. If a local
reproduction is impossible, SAY SO AND STOP — do not reach for the serve.**

## ⛔ Acceptance

1. ⭐⭐ **A LOCAL REPRODUCTION**: a refused write that reports success. **Verbatim,
   with the exit code**, and the ticket's subsequent absence shown.
   ⛔ **If it does NOT reproduce locally, THAT IS THE FINDING — report it and
   stop.** *A defect that needs the serve is a different and narrower defect.*
2. ⭐⭐ **THE HOP WHERE `{:ok, …}` FIRST APPEARS FOR A NON-LANDED WRITE, named as
   `file:line`, WITH THE OBSERVED RETURN VALUE.** *Not "probably here" — the
   value you saw.*
3. ⭐ **RED-FIRST ON THE FIX (hermes's arm, and it is binding): FORCE A REFUSAL
   AND ASSERT A NON-ZERO EXIT.** ⛔ ***A fix verified only against a landing
   write proves nothing about the branch that was broken*** — *same shape as
   `cmp` on two empty files.*
4. ⭐ **THE QUIET HALF: a write that SHOULD land still lands and still reports
   success.** ⚠️ *A fix that makes everything fail passes arm 3 and is worse than
   the bug.*
5. **Tests land as files with their own counts from the tree.**

## ⚠️ Facts you do not need to re-derive

- **ZERO RESIDUE established**: index `scan → 0 orphans` against a live
  instrument (2 entries, 2 visible docs, **258 supersessions**), and the
  973-issue list with a positive control. ⇒ **Nothing was lost; the work was
  never done.** ⛔ **Do not re-measure this.**
- ⚠️ **The ticket body's line numbers `105 / 151 / 160` are STALE** — `create
  :105` now lands on an `["import","issues",path]` clause. ⭐ *A ticket citing
  line numbers has an expiry date.*
- **Unaffected paths**: MCP `bd_*` tools, serve-side erpc. *Those are what the
  reviewer used for 78 ticket writes today, each re-read after writing.*

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace` and report ITS BLOCK; read the
`BEFORE` line.** `host DIRTY 3505/0` · `host CLEAN 3505/0`, seed 117514.
⚠️ **Two sandbox runs disagree — one `3505/2`
(`chat_view_compute_supervisor_test.exs` `:172`, `:143`), the next `3505/0`;
filed `CX-s9kc`, non-deterministic, NOT yours.** ⛔ **Anything else IS yours.**
⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**
⇒ **Never branch on `rc` alone: a real format failure LISTS FILE PATHS.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.**
- ⛔ **NEVER `bd create|update|close` against a REAL archive** — and note the
  host `bd` is now a guard in observe mode; ⚠️ **that is a DIFFERENT tool from
  this ticket's `commonplace bd`.**
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION** — *and its author named the
  wrong locus three times today.* ⛔ **REPORT DISCREPANCIES.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to name a locus from
  reading rather than from an observed value.

## Review criteria

A local reproduction or an explicit statement that it needs the serve; the hop
named as `file:line` **with the value observed there**; a red-first fix forcing a
refusal and asserting non-zero exit; the quiet half preserved; and no locus
claimed that was not measured.
