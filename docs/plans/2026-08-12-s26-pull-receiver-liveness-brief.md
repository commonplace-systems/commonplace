# S26 build brief: pull-federation receiver liveness — CX-5983's three ruled seams (plan #11406)

> Basis: CX-5983, measured live 2026-08-12 during cell slice-2 and ranked
> S26 by plan as the STRONGER half of the runner-arc precondition pair
> (with CX-7cpf) — import-once-invisibly-then-crash-forever is the exact
> opposite of what a remote cell's receive loop must do all day. The
> discriminator work is DONE: the composed failure was decomposed by
> measurement, not inference (evidence @cb703e81,
> `/home/jes/cell-1/evidence-full/42,44,46-*.log`; ticket CX-5983 carries
> the file:line map). This brief is a transcription of plan's ruling; do
> not re-derive the mechanism, fix against it.

## The measured defect (context, not a task)

A receiver that only pulls: (1) imports a plain LINEAR descendant commit —
body lands, `:latest` never advances (MergeAdopter adopts `kind: :merge`
only), so every latest-chain reader (`commit_ids_for_doc`, full-chain
reconstruct, RedLog) cannot see it; (2) the differ builds "what I have"
from the latest-chain walk, so the possessed-but-unadopted commit is
re-offered every cycle; (3) `import_envelope` has no `:already_exists`
clause, so the re-offer raises `CaseClauseError` and kills the WHOLE pull
cycle — every remaining envelope, doc, and peer of that cycle.

## The three ruled seams

(a) **MergeAdopter adopts linear descendants, not only merges**
    (`lib/commonplace/sync/merge_adopter.ex`). The PROPERTY: a
    verified-imported commit that strictly DOMINATES the local `:latest`
    of its doc (local latest is an ancestor, via the existing
    `dominates?/3` walk over `parent_id` + `merge_parents`) becomes
    readable through the standard readers with no manual step. The
    CX-m3x no-clobber rule is the binding constraint and is preserved by
    domination itself: SIBLINGS (neither head an ancestor of the other)
    must remain :skipped — pin that with its own test, red-green. The
    existing walk already handles both shapes; the merge-only guard on
    the function head is the thing that is narrower than its own safety
    argument.

(b) **The differ's denominator is possession, not adoption**
    (`lib/commonplace/federation/pull_client.ex` `diff_missing`): build
    the local set from `all_commit_ids_for_doc/2` — the reader that
    exists (commit_store.ex:817) for exactly this
    imported-but-not-on-the-adopted-chain population.

(c) **`:already_exists` is a per-envelope no-op, never a cycle abort**
    (`pull_client.ex` `import_envelope`): the cycle CONTINUES to its
    remaining envelopes/docs/peers, and the report must not count the
    no-op as `imported` — a quiescent cycle must still read
    `imported: 0`. Whether the no-op gets its own report key is yours;
    the meaning is fixed: "nothing new landed" must remain observable.

Rider (in-license ONLY if trivially adjacent, else name-and-leave):
`RedLog.load` on a genesis-only chain fails as
`{:malformed_update, "decode_uint"}` — a misnamed error for "0-byte
genesis update, chain has no content yet". If the fix is not a rename-
level change, leave it and say so; it is a loudness nit, not this
brief's scope.

## ⛔ Escape hatches, up front

- If adopting linear descendants breaks an existing consumer's
  assumption that `:latest` only moves via local commits or merge
  adoption (Sync.Agent, SiblingMerger, snapshot/reflog machinery —
  enumerate the readers of `:latest` you find and report the list),
  STOP and report the conflict; do not weaken the no-clobber rule to
  proceed.
- `NodeSync.catch_up` (the BEAM-cluster path) has its own diff logic.
  If it shares the same denominator defect, REPORT it — but this
  brief's changes are scoped to the three named seams; do not sweep
  catch_up unless the fix is literally the same helper call.
- No new write surface: adoption fires only inside the existing
  verified-import ingress (`import_with_translation`), same as today's
  merge adoption.

## Tests (red-first from the live corpus)

1. **Adoption arm (the incident, mechanized):** import genesis then a
   linear descendant through `import_with_translation` on a fresh
   store → `commit_ids_for_doc` must contain BOTH; fails today.
2. **Sibling no-clobber pin:** import a sibling of the local head →
   `:latest` unmoved, `:skipped`. Must pass BOTH before and after —
   this is the safety half of seam (a).
3. **Denominator arm:** a possessed-but-unadopted commit (construct a
   sibling import) must NOT appear in the differ's missing set.
4. **Blast-radius arm:** a cycle whose FIRST envelope is
   already-present must still process its SECOND envelope (and report
   `imported` counting only the second) — the property that died in the
   live run.
5. **End-to-end regression of the incident:** genesis cycle, event
   cycle, then a third pull → all readers see 2 commits, third cycle
   reports `imported: 0, errors: []`, no crash.
- Existing MergeAdopter merge-adoption suite stays green untouched.
- Full core counts reported.

## Review criteria

Domination (not commit kind) is the adoption predicate; sibling pin
red-green both sides; denominator uses the possession reader; cycle
continuation demonstrated with a multi-envelope fixture; no-clobber and
no-new-write-surface stated in the diff (moduledoc updated to stop
saying "only merges" the moment that stops being true); reader-of-
`:latest` enumeration reported; red-first transcripts included.
