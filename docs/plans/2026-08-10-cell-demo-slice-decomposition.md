# 2b THE DEMO SLICE — decomposition (ACKED by plan 20:13Z; F1 is the one gate)

**By:** commonplace, 2026-08-10 ~20:25Z · **status: ACKED — both choices
decided by plan (via boss relay 20:13Z, plan read this doc directly).**

- **(A) ACKED: L4 out of the minimal slice, in as slice 2.** Plan additionally
  corrected its own assessment (@23a247c, plan repo): a single-workspace cell
  exercises L4 only degenerately, so "six of seven links" overstated by one.
  Ladder: slice 1 single workspace → slice 2 second workspace over federation
  on this box → L2 remote.
- **(B) ACKED: the serve identity suffices as witness** (a fresh second
  workspace would be independence theatre — same box, same operator). ⛔ **ONE
  CONDITION: the witness record's enclosure must state the same-box/
  same-operator fact explicitly**, so `:corroborated` is honest about what it
  corroborates. Box-level independence stays L2's story.
- ⛔ **THE ONE GATE: F1 (loud WAL-pending line) must merge BEFORE the demo
  runs** — the demo is precisely the scenario where silent WAL-only operation
  would fake success. (In build at ack time.)
- **Step-3 pick (delegated to commonplace, criterion "nothing that could open
  a yelixer investigation"; CX-xqfw class excluded): CX-lgfg via the API
  route** — promote SessionView's `reregister_root_tag/1` workaround into a
  documented Yelixer API with a replay round-trip test. ⛔ Wire format
  untouched — encoding the tag onto the wire would be both an investigation
  and a Yjs-compat hazard, and is out.
- **Contract split for the build**: Sol produces the yelixer change UNSTAGED
  in the cell worktree under its normal contract; the CEREMONY — committing
  through the tapped git as the cell principal, cert mint, witness run — is
  the operator's at top level. The cell's punctuated commit is the operator
  acting as the cell, which is the demo's honest shape until L2 exists.
**Basis:** assessment §5 (acceptance), §3 (the chain), proto-chit schema
`proto-chit-event/v1` (@a66fd9b), CX-8wh1's `Workspace.initialize/2`
(@6567f94 — new, and it changes the cell-birth story below).

## What the slice demonstrates, in one sentence

A local worktree cell — its own workspace, its own principal, the shim on its
PATH — makes ONE real change to `apps/yelixer`, and the substrate ends up
holding: the punctuated history (signed six-field events with real pins), the
pinned candidate, a signed witness from an INDEPENDENT principal that the
targeted suite is green at that pin, and a write cert scoping the cell to the
yelixer subtree — with every link exercised rather than asserted.

## The slice, step by step

1. **Cell birth (L1).** A fresh workspace via `Workspace.initialize/2` —
   which, since @6567f94, IS the real path: identity minted at genuine first
   boot, public keys published, root marker written after the root commit.
   The re-landed mint refusal means a torn cell world refuses rather than
   minting a replacement identity — the demo inherits that protection free.
   The cell's `SigningContext` is its own; the operator's serve identity is
   deliberately NOT reused.
2. **Tap install (L3).** Shim + env (`PROTO_CHIT_*`) pointed at the cell's
   data_dir and a minted event-log UUID, per the schema's pilot scope. The
   worktree's checkout carries `apps/yelixer` source.
3. **The real change.** One genuine, small yelixer improvement WITH a test —
   not a whitespace demo. Candidate source: a yelixer ticket already filed
   (reviewer picks; it must be small enough that the demo's subject stays the
   CHAIN, not the change).
4. **Punctuation.** The change lands via tapped `git commit` → six-field
   event, real reflog pin cut post-sync-flush, predecessor-ref advanced,
   git-sha as annotation. The event's enclosing commit id is the CANDIDATE
   pin.
5. **Witness (L5).** A SECOND principal — the serve's identity, distinct from
   the cell's by construction — checks out the pinned state, runs the
   yelixer targeted suite, and writes a signed witness record carrying the
   VP verdict vocabulary. Independence = different `identity_uuid` on the
   witness write than on the candidate's events, asserted in the artifact.
6. **Cert scope (L6) — AMENDED per CX-b38c + plan's ruling (20:33Z).** The
   write⊥execute belt (trust.ex:534) means a subtree-write cert cannot author
   code-classified docs — BY DESIGN. So: cell code writes ride the cell
   workspace's own node identity (L1 as designed), and the cert machinery is
   demonstrated with THREE controls, the third kept prominent: (a) non-code
   write inside the subtree under the cert LANDS; (b) write outside is DENIED
   (`{:error, {:trust_rejected, :capability_insufficient}}`); (c) a
   code-classified write INSIDE the subtree under the cert is ALSO denied —
   the invariant working, since a write-only cert that could plant
   auto-executing code would be the write→execute laundering hole the belt
   closes. ⛔ **Evidence-doc wording constraint (plan's, verbatim): "cert-scoped
   write demonstrated for NON-CODE writes; code authoring rides node trust
   today, BY DESIGN of the write⊥execute belt; gap filed CX-b38c, shape
   ruled" — never "cert-scoped code contribution demonstrated."** The
   attenuated-code-authoring destination is (i)-shaped (explicit capability,
   write AND execute conjunction or :author_code; route (iii)
   runner-as-author is ruled NOT a route — writer-identity violation);
   mechanism round owed by plan before L2.

## ⚠️ The two choices that are plan's to ack (they shape acceptance, and
## acceptance is plan's §5)

**A. Is L4 (federation transport) IN the minimal slice?** The §5 sentence
("punctuated history, pinned candidate, targeted-suite witness, cert-scoped
write") does not name it; §3 says the demo exercises L1+L3–L7. Proposal:
**OUT of the minimal slice, IN as slice 2** — a second workspace on this box
subscribing over /federation and receiving the punctuation events, run only
after the single-workspace slice is green. Rationale: composition risk is the
stated reason the demo exists; adding transport to the FIRST rehearsal mixes
two unknowns.

**B. Witness independence: is the serve identity an acceptable independent
witness?** It is a different principal with a different key, but the same
box and the same operator. If plan wants stronger independence for the demo,
the alternative is a second freshly-birthed workspace identity playing
witness — more ceremony, same box. Proposal: **serve identity suffices for
the demo**; the independence that matters structurally (cell ≠ witness
principal) is real, and box-level independence is L2's (the runner's) story,
not this slice's.

## What this does NOT touch

- ⛔ L2: no runner. The operator provisions by hand and the cell's key sits
  in the cell workspace — accepted for the demo, named as the gap the runner
  closes (custody ruling: a REAL cell's workload never holds a key).
- ⛔ CX-xgp3's inbound sync — the path is outbound-only by design.
- ⛔ No claim of records-accrue-natively, no authority flip. The git repo
  stays authoritative; the demo produces evidence, not a migration.
- Schema stays `proto-chit-event/v1` as merged; plan's pins-from-spec review
  (owed, upstream) may refine it — the demo re-runs cheaply if so.

## Dispatch shape once acked

Design is done above; the build is operator-ceremony + one yelixer change +
two small connective artifacts (witness record shape, cert mint invocation).
Estimate: one Sol round for the yelixer change under its normal contract; the
ceremony and witness run are MINE at top level (they are judgment and
signing, not mechanical build). The demo's deliverable is a single artifact
document with every link's evidence pasted — the composition rehearsal §6
asked for.
