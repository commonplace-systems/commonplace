# S36 round-1 build brief: storage-SLA slice 0 — the vocabulary and the receipt, EVICT NOTHING — CX-d71s

> **The work's ticket is CX-d71s.** Context labels, none the citation:
> CX-1wt1 (yelixer self-containment) landed @1f94c46b and this follows it
> per plan's order; CX-brxx was S30 (`Cell.Manifest`, whose `sla` block
> this extends); CX-kaah is the cautionary precedent quoted below and is
> NOT fixed here.
>
> **Design source:** commonplace-plan
> `docs/notes/2026-08-12-storage-sla-reaction.md`. jes's words that
> started it: *"some trees are going to have many commits that are
> ultimately kind of low value. they don't need the same SLA as the root
> repo."*
>
> ⛔⛔ **EVICT NOTHING. This round deletes no data, demotes no data, and
> moves no data.** No cold tier, no background mover, no deletion path,
> no reaper. If your change can cause a byte to stop being readable, it
> is out of scope — that is not a style preference, it is the round's
> definition.

## The two things this slice lands

### 1. The tier vocabulary — a measured gap, not a design invention

`Cell.Manifest`'s `@sla_tiers` is currently `~w(durable ephemeral)` —
**two tiers.** The design names **three**: `durable`, `compactable`,
`ephemeral`. `compactable` is the tier the entire demotion story hangs
on, and today it is *unsayable*: a subtree that wants "snapshots survive
at durable grade, pre-snapshot history may later demote" cannot declare
it, so the manifest cannot even record the intent.

Add `compactable` with its validation rule. Note the shape of the
existing rules before choosing: `ephemeral` REQUIRES `retention` (an
ephemeral world must say how long); `durable` does not. Decide what
`compactable` requires and **say why in the code**, not in the commit
message. The tiers' PROMISES belong in the moduledoc, in the design's
own words:

| Tier | Promise |
|---|---|
| `durable` | every commit kept, replicated, hot |
| `compactable` | snapshots survive at durable grade; pre-snapshot history MAY later demote and eventually evict — always with a tombstone |
| `ephemeral` | declared retention window; **pins + tips + witnessed states survive regardless**; the rest expires |

⭐ **The pin-promotion rule is part of the vocabulary, not the
behaviour**: anything pinned is promoted to durable *regardless of its
tree's tier*. Slice 0 states this as a documented, tested predicate —
"would this state survive tier X?" — with NO eviction anywhere to apply
it to. A pure function answering the question is exactly the shape the
later demotion slice will consume.

### 2. The signed tombstone — a format, plus the reader that gives it meaning

Never-rely-on-absence at the storage layer: evicted history must leave a
**receipt** — what range, under which declared SLA, when, and the hash of
what was dropped — signed, and itself durable-grade (*the record of what
was let go is never let go*).

⛔ **THE ROUND'S CENTRAL HAZARD, and the reason this brief is shaped the
way it is:** "land the format with zero behaviour" is *precisely* how
CX-kaah happened — Yelixer's `Doc.gc/1` tombstone-stripping is **fully
built and inert, zero production callers, deleted content retained
forever**, and nobody noticed for months. A format with no writer and no
reader is not a foundation; it is dead code with a good story.

So slice 0's inertness must be **temporary by record, not accidental**:

- **A real writer, exercised in tests.** Constructing and signing a
  tombstone must be a tested code path, not a struct definition.
- ⭐ **A reader wired into the path that actually renders verdicts.** A
  chain walk or verification that encounters a range covered by a
  tombstone must produce a **NAMED** answer — *"evicted per SLA of
  subtree X, tombstone T"* — never a bare not-found. **This is the whole
  point of the receipt: declared eviction must be distinguishable from
  corruption or tampering.** That distinction is the difference between
  a scaling story and a data-loss story, and it is testable today with a
  hand-constructed tombstone even though nothing evicts.
- **A filed successor ticket owning the first production writer**, so the
  gap between format and behaviour is recorded rather than forgotten.
  File it through the gated verb (or report the identity for the
  reviewer, per the filing path below).

## ⛔ Escape hatches, up front

- **EVICT NOTHING**, restated because it is the one that matters: no
  deletion, no demotion, no cold-storage tier, no background job, no
  reaper, no compaction trigger. The CommitStore's append-only property
  is untouched.
- Out of scope by plan's proposed fence: per-object policies, migration
  engines, cache hierarchies, cross-node placement, SLA negotiation
  (that last is VSM resource-contract territory).
- ⛔ **Do NOT fix CX-kaah** (yelixer's inert `Doc.gc/1`). It is cited as a
  precedent, not assigned. Touching yelixer also collides with the arc
  that just stabilised it.
- Existing manifests must keep validating unchanged — `durable` and
  `ephemeral` behave exactly as they do today. If adding a tier forces a
  change to an existing manifest's meaning, STOP and report.
- If the reader's integration point turns out to require a verdict
  surface that doesn't exist yet, STOP and report rather than inventing
  one — name where it would go.
- Telemetry events in scope: NONE.

## Tests (red-first; suites named with counts)

Baseline: full core **3,444 / 1 known CX-5e8s greet-race flake / 1
skipped** @1f94c46b (proven by isolated rerun 4/0 — same population,
green alone). ⚠️ **Run per-app**: multi-app `mix test` paths silently
drop tests in this umbrella.

- **Vocabulary arms**: a `compactable` manifest validates; its required
  field (whatever you rule) is enforced with the field named in S30's
  `{:invalid_manifest, field, reason}` idiom; `durable` and `ephemeral`
  still behave exactly as before (assert the unchanged behaviour, don't
  assume it).
- **Pin-promotion predicate**: pinned state answers "survives" under
  every tier including `ephemeral`; unpinned ephemeral state answers
  "does not survive" — the predicate must be observed giving BOTH
  answers.
- ⭐ **The named-answer arm (the round's reason for existing)**: a walk
  that hits a tombstoned range returns the named, tombstone-citing
  answer — and the **control** is that the same walk over a range with
  NO tombstone returns the ordinary not-found. A reader that says
  "evicted" for everything, or for nothing, is useless; the pair proves
  it discriminates.
- **Signature arm**: the tombstone verifies against its signer, and a
  tampered tombstone FAILS. ⭐ Shape equality is not validity — assert it
  verifies, not merely that its fields match.
- **Evict-nothing pin**: assert by construction that this round adds no
  deletion path (state how you checked; a grep with a control that the
  pattern is findable is acceptable evidence).

## Review criteria

`compactable` sayable with its rule enforced and justified in code; tier
promises in the moduledoc; pin-promotion a tested predicate observed
answering both ways; the tombstone has a real writer AND a reader in the
live verdict path; the named-answer arm has its no-tombstone control;
signature validity asserted rather than field shape; no deletion or
demotion path anywhere in the diff; successor ticket filed or its
identity reported; full core reconciled against 3,444 with per-app runs.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. ⚠️ **The verb is not reachable from inside the sandbox —
that is a capability boundary, not a defect and not a deviation, and it
must not be worked around.** Report finding identities in the evidence
and the reviewer files them.
