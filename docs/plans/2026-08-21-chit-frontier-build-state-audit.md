# Chit epic — frontier build-state audit ([1]–[6]) + post_state census

**commonplace (cell-1), 2026-08-21.** A durable build-state artifact for the chit
epic, filed because the epic keeps getting bitten by stale "exists vs design"
claims: the §8.5 spec description was ~3 revival-series out of date, and used to
*size* step [1] it would have cost four re-implementations of shipped code. This is
the frontier audit the next reader should trip over rather than recall from a
channel. Companion to `docs/plans/2026-08-21-chit-epic-sizing-remeasure.md` (the
projection re-measure, epic step [0]).

Written off: `commonplace-plan/docs/plans/2026-08-21-chit-epic-step1-foundation-brief.md`
(step [1] brief, §4 mandated this audit) and `2026-08-21-chit-epic-build-sequencing-brief.md`
(the epic). commonplace owns the audit; commonplace-plan owns the ORDER.

## Scope, bound into the artifact

- **As-of 2026-08-21.** Code claims are from the main working tree at HEAD
  (`be990e6f`+); each load-bearing claim was verified directly (file:line), not
  taken from the survey alone.
- **The census** ran offline against a fresh `CubDB.back_up` copy (12:23Z;
  non-perturbation verified — 0 `Commonplace.*` modules force-loaded on the live
  serve), read-only, positive controls both arms.
- **Build-state is a fact that goes stale like any other.** This doc is a snapshot;
  a later reader must re-derive before sizing on it (the whole reason it exists).

---

## Part A — Step [1]/[2] preconditions: the dormant-machinery description is STALE

The §8.5 claim ("checkpoint walk + reflog DORMANT: drivers don't run on Mode-B;
writes predate signing; pin-read is a genesis-crashing defp") is ~3 revival-series
out of date (CX-0t2r + CX-6scm + CX-ggdv landed after it). Verdicts:

| §8.5 "to build" | Current state | Verdict |
|---|---|---|
| Dormancy fix (make walk runnable) | `CheckpointTimer` wired into the supervision tree (`application.ex:188,546` `reflog_children/0`), gated on `COMMONPLACE_REFLOG_ON_BOOT` (default OFF, staged separate from code-deploy per CX-0t2r, both Mode-A `serve.ex:54` and Mode-B `runtime.exs:124`). **NOT set on live serve 664985** (`/proc/664985/environ`). | **DRIFT** — dormant on the live serve by a *staging gate*, not missing wiring |
| Signing-context threading | `Snapshot.checkpoint/4` resolves signing_context once (`NodeIdentity.signing_context/0`) and threads it through every `create_chained_commit/5` via `signed_opts` (`snapshot.ex:203-245`) | **DONE** (CX-0t2r) |
| Pin-read genesis-crashing defp | Still a `defp` (`restore.ex:304`) but now a **genesis-safe thin adapter** over the promoted public `Projection.project_doc_at` (CX-6scm); genesis → empty doc (F7), `{:unknown}` surfaced as a NAMED refusal, never silent-wrong | **CONFIRMED drift** (defp yes, crashing no) |
| Step [2] public genesis-safe pin-read API | `Projection.project_at/3` / `project_doc_at/3` ARE that API today | **DONE** — [2] folds |
| Commit-verb wiring | `commonplace checkpoint` verb (`cli/checkpoint.ex`) + `CheckpointTimer` drive the walk under signing today; there is NO `commit -m` verb | naming/UX choice deferred to [3] (a chit `commit` is more than a checkpoint) |

**Walk-bounding (step [1]'s one real residual) — CLOSED, both ways:**
- CODE: every per-node read in the checkpoint walk is O(1) — `latest_commit` for
  `:doc` entries, `reconstruct_snapshot` for schemas (`load_schema`, snapshot.ex:633)
  — **never `reconstruct_doc`**. So the walk is O(tree), never O(history). The
  re-measure's "full-history-linear" was about per-doc PIN reads (`chain_to`,
  already bounded by CX-ggdv) — a *different* walk. The "residual" was a conflation.
- TEST (filed, green — ran `snapshot_test.exs`: 16 tests, 0 failures): fast-path
  read-skip on a clean subtree (line 237, CX-o8tx), write-skip on an unchanged tree
  (149), one-file-change writes only along its path (180), cold-start walks the whole
  tree (313). Signed-walk end-to-end: "checkpoint commits carry the node signer_id"
  (444).

**⇒ Steps [1] and [2] are COMPLETE.** The foundation was pre-built; its one
unverified claim is now demonstrated by a permanent green suite (a filed artifact
fires — no throwaway harness). Enabling reflog on the live enforce serve is a
deploy-class staging act (it starts WRITING checkpoints into the live store) — jes's
decision, not a frontier blocker; [3]–[6] build regardless.

---

## Part B — Frontier build-state [3]–[6]

The spec's "grep found zero" is TRUE for the named *types* (`CellGeneration`,
`ChitObject`, `ContractCell`, `ClosureResolver`, `git_export` all absent) but too
narrow: the *substrate* they'd sit on largely exists.

### [3] chit OBJECTS + CAS placement + branch-ref doc — **DESIGN-ONLY-ABSENT** (substrate built)
- No canonical chit type `{tree-pin, parents, author, message, sig}` in CAS (grep 0).
- CAS exists, but only for **commit rows** (content-addressed, `commit.ex:141`;
  put/get `commit_store.ex:709/735/975`) — not a distinct chit object.
- No branch-ref *doc*. proto-chit persists **events** via `RedLog` commit rows
  (`proto_chit.ex:291/302`), builds a `proto-pin` map (`:232`), and writes a
  branch→event-ref map to **on-disk `predecessors.json`** (`:342/512`).
- **Remains:** the canonical `Chit` type + its CAS (or a decision to reuse commit-row
  CAS) + promote `predecessors.json` from disk-JSON to a store **doc** (the branch-ref).

### [4] chit ANCESTRY invariant (fork-lineage-aware) — **DESIGN-ONLY-ABSENT** (merge ancestry live)
- No chit ancestry invariant. `Invariants.Registry` has 6 invariants, all bd-domain.
- `find_common_ancestor` is BUILT (`commit_store.ex:1461/3464`) but serves
  merge/PR/fork (document ancestry), reusable for chits.
- The `{:doc_commit}` index (`commit_store.ex:12`) is the fork-lineage-aware seam
  (re-measure Finding 2: 1.9% of heads carry a foreign struct `doc_uuid`).
- **Remains:** an ancestry / parents-are-checkable-claims invariant over chit objects,
  keyed on `{:doc_commit}` fact (NOT naive `:latest` doc_uuid), registered in the
  Registry, reusing the `find_common_ancestor` DAG walk.

### [5] verified-projection LAYER — **BUILT** (the spec's "PARTIAL" undersells it)
- Read-side: full API (`project_at/3`, `project_doc_at/3`, `project_history/3`);
  all 3 tiers (`select_tier` proj.ex:583: hash arbitration / HEAD dual-path TOCTOU /
  historical dual-path); all verdicts (`:witnessed` | `{:corroborated, methods}` |
  `{:declared, path, _}` | `{:unknown, {:conflicted|:mixed_plane, _}}` | `{:error, _}`);
  signature threading (`verify_chain_integrity`); mixed-plane tripwire at pin reads;
  `:declared` excluded from the witnessed/corroborated floors.
- Write-side mint: `commit_builder.ex:67/96` (`mint_post_state`), `Commit.post_state_hash`
  inside the content address, `PostState.mint/compare/canonical_bytes`.
- Acceptance suite present: `projection/acceptance_test.exs` #1–#10.
- **Gaps are COVERAGE, not the layer:** (i) mint is opt-in per call site — census below
  shows **0%** of commits carry a post_state_hash; (ii) the "merkle-tracked-yjs
  canonical" candidate is not wired (uses `Yelixer.encode_update` + a version tag —
  intent met by simpler machinery); (iii) consumers not all routed through it —
  notably GitBridge export ([6]) bypasses it.

### [6] EXPORT function (render-at-pin) — **PARTIAL**
- GitBridge exporter is **HEAD-ONLY**: `exporter.ex:206/272/279` use
  `reconstruct_doc` / `latest_commit` / `reconstruct_snapshot`, no pin param, and it
  **never calls `project_at`** — so export bytes carry no verdict.
- Reusable at-pin machinery EXISTS elsewhere: `DocBuilder.reconstruct_doc_at/4`, and
  `Black.select`'s whole-tree `at_pin` (`%{uuid => commit_id}` → `reconstruct_doc_at`,
  `black.ex:192/195/528`).
- **Remains:** thread a pin through `Exporter.export/walk` (schema loads + manifest
  anchors all currently assume head), reusing `Black`'s `at_pin` pattern and routing
  through `Projection.project_at`.

---

## Part C — post_state_hash + signature census (the [6]-sizing input)

Full commit population from the `{:doc_commit}` index: **79,005 commits**
(missing_row 0 — complete denominator). Positive controls both arms (reader
distinguishes present/absent hash, signed/unsigned).

| coverage | count | % | what it buys in `project_at` |
|---|---|---|---|
| carry `post_state_hash` | **0** | **0.0%** | tier-(i) `:witnessed` — **unavailable anywhere** |
| SIGNED (`signer_id`+`signature`) | **28,238** | **35.7%** | tier-(ii) signature-based `:corroborated` / **loud tamper catch** (acceptance #1) |

By kind (signed / total): `:regular` **16,995 / 17,045 (99.7%)** · `:snapshot`
178/205 (86.8%) · `:git_bridge_inbound` 3/3 · `:genesis` 1/5,793 (synthetic,
unsigned by design) · `:unknown` **11,061 / 55,959 (19.8%)** — the `:unknown` legacy
bulk predates signing.

**What this decides for [6]-wiring:** F4's tamper-blindness (62% of byte-flips
absorbed) is a *reconstruction-layer* property; `project_at` adds a **signature**
layer that catches an absorbed flip *loud* on a SIGNED commit (the flip breaks the
signature regardless of whether reconstruction absorbs it — acceptance #1). So:
- Wiring export through `project_at` at a pin makes verdicts **honest universally**
  (`:conflicted`/`:declared` named, never silent) and **DETECTS tamper on the signed
  corpus** — which is ~99.7% of `:regular` commits, i.e. the commits a chit would
  actually pin.
- It does **not** reach `:witnessed` (needs post_state, 0%) and does **not** detect
  tamper on the unsigned legacy `:unknown` bulk.
- ⇒ **[6]-wiring alone suffices IF a chit pins modern signed commits** (the expected
  case). `[5]`-mint-coverage (thread `:post_state` through all mint sites) OR a legacy
  signing-backfill rides with [6] only if chits must *verify the unsigned legacy
  commits*. That is plan's sizing call, and it now rests on measured coverage, not an
  inference.

---

## The re-scope insight, and the ORDER (commonplace-plan's decision)

**[5]+[6] are coupled and are the real leverage.** The verified-projection layer
EXISTS but is not ON THE EXPORT PATH (exporter bypasses `project_at`; mint is opt-in)
— which is exactly why re-measure Finding 4's tamper-blindness is live in practice.
Wiring export-at-pin through `project_at` (reusing `Black.at_pin`) simultaneously
builds [6] AND discharges the F4 dependency [5] was created for: one move closing two
items and a live finding.

**ORDER (commonplace-plan #14308): [6]-wiring goes AHEAD of [3]'s new type** — it
discharges a measured live risk by composing existing pieces, and a chit whose export
is tamper-blind would be unverifiable, defeating "git-work-alike better than git."
[3]/[4] follow on their strong seams (commit-row CAS + proto-pin for [3];
`find_common_ancestor` + `{:doc_commit}` for [4]), inheriting a trustworthy export.

## Honesty note (the trap this audit itself nearly hit)

The survey inferred "0 commits carry post_state_hash ⇒ [6]-wiring can't get
meaningful verdicts." The first half is now *measured* (0.0%); the second half was a
measurement-of-X-supporting-a-claim-about-adjacent-Y error — meaningful tamper
detection rides on the **signature** coverage (35.7% overall, 99.7% of `:regular`),
not on post_state_hash. Both numbers are reported so the [6] sizing rests on the
right one.
