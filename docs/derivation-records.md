# Derivation records

CX-vt9l.2 (epic CX-vt9l, slice 2). Source doc (authoritative, not a beads
target): `/home/jes/commonplace-plan/docs/plans/2026-08-04-relational-search-ideation.md`
§2b, cross-referenced against the tree-pins structural definition (CX-osaf,
`/home/jes/commonplace-plan/docs/plans/2026-08-03-tree-pins-design.md`).

Labels below: **VERIFIED** means I read the cited code and confirmed the
claim against it. **DESIGN** means this is the convention being proposed
here, not something already built. Nothing in this page is marked
"implemented" unless it was actually read.

## The shape

A **derivation record** is a 4-tuple:

```
(sources_pin, transform_ref, output_ref, signer)
```

* `sources_pin` — `%{doc_uuid => commit_id}`, the exact cut the transform
  read. This is not a new pin type: it is the same shape
  `Commonplace.Black.Query` already produces and documents —
  `@type pin :: %{optional(String.t()) => binary()}`
  (`apps/commonplace/lib/commonplace/black/query.ex:88`). **VERIFIED.**
* `transform_ref` — names *which computation, which version* produced the
  output (a code-doc uuid, an algorithm-version tag, or a `{uuid,
  commit_id}` pair).
* `output_ref` — names the produced artifact (typically `{doc_uuid,
  commit_id}`; a filesystem path is valid too — see the `materialize_dir/4`
  adoption below, which writes plain files, not a commonplace doc).
* `signer` — who computed it, or `nil` if unsigned.

## The point

Content is entirely `@`-refs (`sources_pin`, `transform_ref`, `output_ref`)
plus a signature (`signer`) and a label (`computed_at`) — nothing here is
computed state. That makes a derivation record structurally a **witness
doc**, per the tree-pins definition (CX-osaf): a doc whose content is
refs-and-labels-only is self-verifying to the same standard as any other
witness — anyone holding the pin can re-run the transform and compare.

The **derived artifact** the record describes (index bytes, a materialized
table, a rewritten view doc) is emphatically *not* a witness doc — it holds
real computed content, is not self-verifying, and must not be treated as
ground truth. But because the record names the exact cut the artifact was
computed from, the artifact is fully **regenerable** from the record plus
the transform. That is what turns "cache, not ground truth" from a slogan
into a *checkable* property: staleness is decided by comparing
`sources_pin` against the store's current heads — never inferred from
"looks fresh" or "was recomputed recently." `Commonplace.DerivationRecord.stale?/2`
(`apps/commonplace/lib/commonplace/derivation_record.ex`) does exactly this
comparison, and is designed so an unreadable source reports `{:unknown, _}`
rather than silently reporting `:current` — collapsing "I can't tell" into
"it's fine" is the specific failure class this convention exists to close.
**DESIGN** (the record + `stale?/2` are new, built for this bead;
round-trip/structure/staleness-decidable tests live in
`apps/commonplace/test/commonplace/derivation_record_test.exs`).

## The three precedents

### 1. The late-edit `derivation_map` — regenerable, not authoritative

`Commonplace.Store.Snapshotter.build_payload/2` builds a snapshot's
`derivation_map` (`%{new_id => old_id}`, wrapped under the parent
namespace) alongside the snapshot's `update` bytes
(`apps/commonplace/lib/commonplace/store/snapshotter.ex:138-158`). The
moduledoc states the load-bearing property directly: "`snapshot_update/1`
is byte-deterministic across Yelixer instances that hold the same logical
state ... any node that observes the same parent independently builds
*byte-identical* snapshot content" (`snapshotter.ex:35-47`).
`Commonplace.Store.CommitStore.snapshot/2`'s own doc says the same thing
about the map specifically: "Two independent nodes snapshotting the same
parent produce the same `update` bytes and the same `derivation_map`
contents (deterministic-anyone property)"
(`apps/commonplace/lib/commonplace/store/commit_store.ex:566-569`, see also
the three-layer discussion at lines 168-195). **VERIFIED.** The map is
never the sole source of truth for "what maps to what" — it is a
performance artifact (skip re-deriving the map by hand) that any peer can
independently reproduce from the source doc's own state. That is the
regenerable-cache property this convention generalizes.

### 2. Snapshot compaction's two-layer pattern

Same module, two layers with different hash-membership:

* **Artifact layer** — the snapshot `update` bytes + `derivation_map` +
  `snapshotter_version` (`snapshotter.ex:86-89,138-158`). Deterministic
  over the input frontier; the version tag is folded into the payload so
  any peer computing the same parent state produces byte-identical output,
  and the content-addressed commit id collapses concurrent attempts into
  one commit (`write_snapshot_cas/5`, no leader election needed) — see
  `commit_store.ex:185-190`. **VERIFIED.**
* **Announcement layer** — `timestamp`, `signature`, `signer_id`. These are
  explicitly *excluded* from the content-addressed commit id:
  `Commonplace.Store.Commit`'s moduledoc states "these fields are
  deliberately excluded: `timestamp` (wall-clock, stamped at commit time,
  which would make two functionally-identical commits ... hash
  differently) ... and `signature`/`signer_id`"
  (`apps/commonplace/lib/commonplace/store/commit.ex:51-57`, fields listed
  at lines 171-173). **VERIFIED.** This is exactly the artifact/announcement
  split a derivation record's `output_ref` (points at the artifact-layer
  commit) vs. `signer`/`computed_at` (envelope-only, not load-bearing for
  staleness) generalizes.

### 3. ViewCompute's inline proto-record

`Commonplace.ViewCompute` is a GenServer that recomputes a target doc when
its source changes and tracks `last_computed_at` in its own state
(`apps/commonplace/lib/commonplace/view_compute.ex`, defstruct at
lines ~116-141, set on every successful recompute at
`handle_call(:recompute, ...)` and the async DOWN handler). **VERIFIED —
but narrower than the source doc's §2b claim.** §2b describes the
precedent as "source / computed-at / signer / stale / stale-relative-to."
Of those, only `computed_at`-equivalent (`last_computed_at`) is actually
carried by the `ViewCompute` GenServer's own state.  `source` /
`signer` / `stale` / `stale-relative-to` are a *separate* thing: an XML
attribute convention on VIEW DOC CONTENT itself, parsed (but "not yet
surfaced in the UI") by `CommonplaceWebWeb.ViewRenderer`
(`apps/commonplace_web/lib/commonplace_web_web/live/view_renderer.ex:58-59,101,439`).
Nothing in `ViewCompute` itself writes those attributes — that's left to
whatever `compute_fn`/`code_uuid` transform produced the content. So the
"proto-record" is real but split across two places, and only half of it
(`last_computed_at`) is GenServer-owned. **This page's adoption (below)
replaces the GenServer-owned half with a proper derivation record; the
XML-attribute convention is a separate, content-level concern this bead
does not touch.**

## Adoption (CX-vt9l.2, additive — behavior-preserving)

Per the bead's scope correction (verified against code, see epic
CX-vt9l's §6-correction and CX-5le4): the source doc's §7 says to adopt in
"ViewCompute and the frontier views." **The frontier views are not a valid
target.** `__ready.json`/`__blocked.json` are written only by
`Bd.Frontier.Server`
(`apps/commonplace/lib/commonplace/bd/frontier/server.ex:29-32,138,221-228`),
and that server has **zero production starters** — grepping the
application supervision tree turns up only self-references, already filed
as CX-5le4. `frontier.ex` itself (the live, `bd`/MCP-called half) contains
no alarm/view-doc code at all. There is nothing live to adopt into.
**Conditional**: once CX-5le4 gives `Bd.Frontier.Server` a production
starter, its `__ready.json`/`__blocked.json` writes are a legitimate third
adoption target (the sources_pin would be the ticket-graph cut the
frontier computed over). Not built here.

Adopted instead, both additive (existing callers see unchanged return
shapes/fields; the record rides alongside):

1. **`Commonplace.ViewCompute`** — every successful `do_compute_work` write
   now also builds a `Commonplace.DerivationRecord` (`sources_pin =
   %{source_uuid => latest_commit_id}`, `transform = code_uuid ||
   :inline_compute_fn`, `output = {target_uuid, latest_commit_id}`) and
   posts it back to the GenServer's own state as `:derivation_record`
   (`view_compute.ex`, `emit_derivation_record/2`). `last_computed_at` is
   untouched. Caveat, documented in code: `sources_pin`/`output` are each
   read via a **separate** `latest_commit` call after the write completes,
   not threaded atomically through the read/write — a best-effort
   provenance label, not a transactional guarantee. Test:
   `apps/commonplace/test/commonplace/view_compute_test.exs` ("CX-vt9l.2:
   carries a derivation record alongside last_computed_at, additive").

2. **`Commonplace.Reflog.Restore`** — the checkpoint/restore artifacts
   (CX-0t2r, live and genuinely two-layer: the reflog `__snapshot` doc is
   the announcement, the materialized tree is the artifact):
   * `materialize_branch/5` returns `{:ok, %{root_entry:, docs:,
     derivation_record:}}`. `sources_pin` is the single `%{snapshot_doc_uuid
     => checkpoint_commit_id}` pin — the same two identifiers the function
     itself takes, and the exact pin `resolve_anchored/4` walks to
     reproduce the whole branch. `output` is `{new_root_uuid,
     commit_id}`.
   * `materialize_dir/4` returns `{:ok, %{files:, dest:, witness:, at:,
     derivation_record:}}`. `sources_pin` is `resolve/3`'s own
     `%{path => {:file, doc_uuid, commit_id_hex}}` result reshaped into the
     `{doc_uuid => commit_id}` pin shape. `output` is the destination
     filesystem path (not a doc — `materialize_dir/4` writes plain files).
   * Tests: `apps/commonplace/test/commonplace/reflog/restore_test.exs`
     and `.../checkout_test.exs` ("CX-vt9l.2: ... carries a witness-shaped,
     decidably-stale derivation record" in each), including a live
     staleness-detection case (mutate a pinned source after
     materialization → `stale?/2` names exactly that source).

## The module

`Commonplace.DerivationRecord`
(`apps/commonplace/lib/commonplace/derivation_record.ex`):

* `new(sources_pin, transform_ref, output_ref, opts \\ [])` — builds the
  canonical map (`opts: :signer, :computed_at`).
* `witness?(record)` — structural check: true iff `record` carries only
  the allowed ref/label keys (`sources_pin`, `transform`, `output`,
  `signer`, `computed_at`) — false the moment any computed state (a row
  count, an index byte size) rides along.
* `stale?(record, store \\ CommitStoreClient)` — `:current` |
  `{:stale, [doc_uuid]}` (named, not "something changed") |
  `{:unknown, reason}` (a source's `latest_commit` read failed or returned
  `:none` — never silently folded into `:current`).
