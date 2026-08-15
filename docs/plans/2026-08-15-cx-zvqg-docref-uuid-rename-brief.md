# CX-zvqg build brief: the name has to carry the contract

> **The work's ticket is `CX-zvqg`.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## The defect — verified at source before briefing

`Commonplace.Document.DocRef` documents a pinnable reference:

```
Format: `path:uuid@cid`
  cid — optional commit ID (hex-encoded, FOR PINNING TO A SPECIFIC VERSION)
  notes/todo.txt:<uuid>            — latest version
  notes/todo.txt:<uuid>@a1b2c3d4   — pinned version
```

**But `resolve/1` (grep `def resolve(%__MODULE__{uuid: uuid})`) returns
`{:ok, uuid}` and DISCARDS the cid. Silently. No error. `{:ok, …}`.**

⇒ ⛔ **A ref carrying a correct pin and a ref carrying none become THE SAME VALUE
at the call site, with no observable difference.**
⇒ ⭐⭐ **Returning the uuid is a LEGITIMATE operation** — a caller often wants
exactly *which document*, pin irrelevant. ***The defect is that a function called
`resolve` accepts a ref carrying a pin and drops the most specific thing its
argument carries.*** ⚠️ *It is the discarded-return class wearing an ARGUMENT
instead of a return value: the CALLER'S INTENT is dropped rather than the
callee's outcome.*

## ⛔ THE RULED FIX IS THE RENAME. A SAFE SIBLING IS REFUSED.

**Rename the pin-dropping function to `uuid/1`** (or `doc_uuid/1` — state which
you chose). **Then `resolve/1` either honours the pin or does not exist.**
⇒ ⭐ **A call site reading `DocRef.uuid(ref)` makes the dropped pin OBVIOUS
rather than silent.** ⇒ ✅ **No safe/unsafe pair is created, so there is no
partial-adoption surface to enumerate later.**

⛔⛔ **`resolve_pinned/1` WAS CONSIDERED AND REFUSED, and the reason is measured
rather than aesthetic: that is exactly `create_text_doc` / `create_text_doc_checked`
— a safe sibling beside an unsafe original, documented, partially adopted.**
**`CX-1czm` cost six sites and a day to close, AND THE PARENT IS STILL UNBOUND
TODAY.** ⇒ ***Do not propose that shape again; we measured its failure mode.***

⚠️ **IF a sibling turns out to be unavoidable for compatibility, THE CALLER-
ENUMERATION GUARD SHIPS IN THE SAME ROUND** (the `CX-3vgy` pattern, red-first by
adding a temporary offending caller) — ***a remedy without an enumeration is a
rule nobody can be found to have broken.*** ⛔ **And say so loudly rather than
quietly adding one.**

## ⛔ Acceptance — artifacts

1. ⭐⭐ **EVERY CALLER MIGRATED, AND THE COUNT STATED.** ⛔ **`resolve/1` must not
   survive as a silent alias.** *Grep the tree; `DocRef` is used across apps.*
2. ⭐⭐ **A CALLER THAT GENUINELY WANTS THE PIN IS IDENTIFIED, OR THE ABSENCE IS
   STATED.** ⚠️ **`Identity.ClassRatification.read_pinned/2` and
   `Runner.DeploymentRecord.read_promoted/2` BOTH refuse an unpinned ref
   (`:class_version_required`, `:promotion_version_required`) — they parse the
   ref themselves rather than going through `resolve/1`.** ⇒ ⭐ **Check whether
   any caller was silently losing a pin it needed. THAT is the finding if it
   exists; "no such caller" is also a finding and is worth stating.**
3. ⭐ **THE SUITES STAY GREEN**, and the count is taken from the tool's own block.
4. ⭐ **PRINT WHAT CHANGED**: the number of call sites, and the list.
5. **Lands as files with their own counts from the tree.**

## ⚠️ What this is NOT

⛔ **Do NOT add pin-honouring behaviour to `resolve/1` as part of this round.**
**The ruling is the rename; making a `resolve/1` that honours pins is a
different, larger change and it would land unenumerated.** ⭐ *If you believe the
honouring form is required, SAY SO and stop — that is a discrepancy report, not a
scope decision.*

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**`node_signing_key` is MASKED in your fence** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` **FAILS and no node-signed
write succeeds.** ⭐ **Use the injectable `opts[:signing_context]` seam.**
*This round is mostly a rename, so it may not arise — but a test that writes will
hit it.*
⚠️ **A full suite DOES run in a worktree despite the baseline block saying "no
repo `deps/`" — S71 ran 3506 tests inside one.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.** ⚠️⚠️ **THE BASELINE HAS MOVED FIVE TIMES TODAY. TAKE THE COUNT
FROM THE TOOL'S OWN BLOCK, NOT FROM THIS BRIEF.** *For orientation only, it was
`3518 / 0` at seed 117514 after `CX-fmzk`.*
⚠️ **This touches a shared type, so name suites by BLAST RADIUS, not by the app
you edited** — `DocRef` is used beyond `apps/commonplace`. ⛔ **Check the other
apps.**
⚠️ **`CX-s9kc`: sandbox `chat_view_compute_supervisor_test.exs` flake,
non-deterministic, NOT yours.** **Anything else IS yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *The last four rounds' most valuable contributions were all corrections to
  their briefs rather than compliance with them.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to leave `resolve/1` as
  an alias "to keep the diff small", or to add the sibling without an enumeration.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

The rename landed with EVERY caller migrated and the count stated; no surviving
alias; no safe/unsafe sibling (or, if unavoidable, its caller-enumeration guard
in the same round and loudly declared); pin-needing callers identified or their
absence stated; suites named by blast radius across apps and green.
