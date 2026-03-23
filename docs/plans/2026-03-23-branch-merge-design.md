# Branch Merge Design

> Design for CX-v4q: Merge across branches.
> Discussed 2026-03-23 in #loom between commonplace and commonplace-plan.
> Reviewed by Codex — 6 findings incorporated (see Revision Notes at end).

## Overview

Merge brings changes from a **source** branch into a **target** branch. The source is unchanged. This is directional, like `git merge`.

The ForkManifest (CX-89r) provides the provenance map: for every document in the forked branch, it records the original UUID and the fork-point commit. This is the foundation for merge.

## Prerequisites

- **ForkManifest** (CX-89r, done): tracks `new_uuid → {original_uuid, fork_point_commit}`
- **CommitStore**: stores commits with Yjs updates and parent chains
- **Yelixer state vectors**: `BlockStore.state_vector/1` and `Encoding.encode_state_as_update/2` for computing diffs

## Key Constraint: Schema Docs Cannot Be CRDT-Merged Directly

Schema docs embed `node_id` UUIDs that are branch-specific. A source schema entry `"file.txt" → source-uuid-123` must not be applied verbatim to the target tree — that would make the target point at a source-branch document, breaking branch isolation.

**Schema merge must happen at the application level**, not via raw CRDT update application. We diff the schema entries structurally, then apply changes with UUID translation.

## Merge Algorithm

### Step 1: Load ForkManifest

The source branch has a ForkManifest recording which target doc each source doc was forked from, and the commit at which the fork occurred.

```
manifest.document_map = %{
  "source-doc-uuid" => %{
    original_uuid: "target-doc-uuid",
    fork_point_commit: <<commit_id>>
  }
}
```

Build a reverse map for lookups: `source_uuid → {target_uuid, fork_point_commit}`.

### Step 2: Merge Known Documents (Content)

For each document that existed at fork time (entries in the manifest):

1. Load the source doc's full Yjs state (replay all commits since fork_point)
2. Reconstruct the fork-point state vector from the fork_point_commit's Yjs update
3. Compute the diff: `Encoding.encode_diff(source_doc, fork_point_state_vector)`
   - This gives "all Yjs updates in the source that happened after the fork"
4. Apply that update to the target doc: `Encoding.apply_update(target_doc, diff)`
   - CRDT merge handles conflicts automatically — concurrent edits to the same text are resolved deterministically by client ID ordering
5. Commit the updated target doc to the CommitStore

### Step 3: Compute Schema Diff

Compare the source schema at three points:
- **Fork-point schema**: load using the fork_point_commit for the source root
- **Current source schema**: load latest
- **Current target schema**: load latest

Diff the fork-point schema against the current source schema to find:
- **Added entries**: in current source but not at fork-point
- **Removed entries**: at fork-point but not in current source
- **Renamed entries**: same node_id under a different name (detected via node_id matching)

### Step 4: Apply Schema Changes to Target

#### Added entries (new docs/dirs created on source after fork)

1. Copy the source document content to a new target UUID (mini-fork)
2. Add the new UUID to the target schema under the same name
3. **Add provenance to ForkManifest**: `{new_target_uuid → {source_uuid, current_source_commit}}`
   - This ensures future incremental merges can track changes to these documents

For new directories: recurse — fork the entire subtree with new UUIDs (reuse `Fork.fork_directory`).

#### Removed entries (docs/dirs deleted on source after fork)

**Do not blindly unlink.** Check for delete-vs-modify conflict:

1. Look up the target doc's UUID via the manifest
2. Load the target doc's current commit
3. Compare the target doc's state with its fork-point state
   - If target is **unchanged** since fork → safe to unlink from target schema
   - If target has **modifications** since fork → **conflict**: source deleted, target modified
4. For conflicts: record in a merge report, do NOT unlink. The user decides.

#### Same-name collisions

If both source and target independently added an entry with the same name but different UUIDs:

- YMap is last-writer-wins — raw CRDT merge would silently drop one version
- **Detect before applying**: compare source additions against target additions (entries present in current target but not at fork-point)
- If collision detected: **conflict**. Record both UUIDs in the merge report. Do not overwrite.

#### Renames

If a source entry was renamed (same node_id, different name):
1. Find the corresponding target entry via manifest UUID mapping
2. Remove the old name from target schema
3. Add the new name pointing to the same target UUID

### Step 5: Apply __processes.json Fork-Safety

When merging schema changes that include `__processes.json`:

- Use `Config.fork_behavior/1` — the same function used by fork (CX-89r)
- This respects explicit `"fork": "copy"/"skip"` annotations and mode-based defaults
  (elixir → copy, sandbox-exec/command → skip)
- Only entries with `:copy` behavior are merged into the target
- Do NOT restate defaults in the merge doc — reference `Config.fork_behavior/1` as the single source of truth

### Step 6: Update Fork Point (Atomically)

After all content and schema changes are applied:

1. Update each manifest entry's `fork_point_commit` to the current source commit
2. Add new manifest entries for post-fork documents (Step 4)
3. Persist the updated ForkManifest

**Ordering for crash safety**: Apply all target commits first, then update the manifest last. If a crash occurs between content application and manifest update:
- Next merge re-computes diffs from the old fork_point
- CRDT `apply_update` is **idempotent** — re-applying the same Yjs updates has no effect
- This makes the non-atomic case safe: worst case is redundant (but harmless) re-application

The manifest update is the "commit point" of the merge operation.

## Merge Report

Every merge produces a report:

```elixir
%MergeReport{
  merged_docs: [{source_uuid, target_uuid}],     # successfully merged
  new_docs: [{source_uuid, new_target_uuid}],     # copied to target
  deleted_docs: [target_uuid],                     # unlinked from target
  conflicts: [
    {:delete_vs_modify, name, target_uuid},        # source deleted, target modified
    {:name_collision, name, source_uuid, target_uuid},  # both added same name
  ]
}
```

The merge function returns `{:ok, updated_manifest, report}` or `{:error, reason}`.

Conflicts do NOT block the merge — non-conflicting changes are applied, and conflicts are reported for manual resolution.

## API

### Elixir Module

```elixir
Commonplace.Tree.Merge.merge(source_uuid, target_uuid, manifest, store)
# Returns {:ok, updated_manifest, merge_report} or {:error, reason}
```

### CLI

```
commonplace merge <source-path> <target-path>
```

Looks up the ForkManifest to find the provenance mapping, performs the merge, prints the report. Conflicts are listed with instructions for resolution.

## Edge Cases

### Document Modified on Both Branches

CRDT handles this automatically in Step 2. Both sets of edits are preserved. For text documents, concurrent insertions at the same position are ordered deterministically by client ID. No data is lost, though the result may need human review.

### Circular or Repeated Merges

The fork_point update (Step 6) prevents re-applying already-merged changes. Each merge advances the fork point, so the next merge only sees new changes. CRDT idempotency provides a safety net if the fork_point update fails.

### Nested Directory Changes

If a subdirectory was added on the source branch, the entire subtree is forked into the target (reusing `Fork.fork_directory`). The subdirectory's ForkManifest entries are merged into the parent manifest so future merges track the full tree.

### Empty Merge

If no changes occurred on the source since the last merge (or fork), the merge is a no-op. The fork_point is not advanced (nothing to advance to).

## Future Considerations

- **Merge commits**: Record a commit on the target with metadata pointing to both pre-merge target commit and source commit as parents (DAG branching)
- **Conflict resolution CLI**: `commonplace resolve <conflict-id>` to choose source or target version
- **Three-way merge visualization**: Show fork-point state, source state, and target state side by side
- **Cherry-pick (CX-b70)**: Merge a single document's changes instead of the whole branch
- **Bidirectional merge**: Merge target changes back into source (requires reverse manifest)

## Revision Notes

Incorporated feedback from Codex review (2026-03-23):

1. **Schema node_id remapping** (P1): Schema docs cannot be CRDT-merged directly because node_ids are branch-specific. Schema merge now happens at the application level with explicit UUID translation via manifest mappings.

2. **Post-fork document provenance** (P1): New documents copied during merge (Step 4) now get ForkManifest entries, enabling future incremental merges to track them.

3. **Delete-vs-modify detection** (P1): Deleted entries are no longer blindly unlinked. Target-side modifications since fork are detected and flagged as conflicts rather than silently orphaned.

4. **__processes.json policy alignment** (P2): Merge references `Config.fork_behavior/1` directly rather than restating defaults, ensuring consistency with fork logic.

5. **Same-name collision handling** (P2): YMap last-writer-wins behavior is acknowledged as data-loss-prone. Same-name additions on both branches are detected pre-merge and flagged as conflicts.

6. **Atomic manifest advancement** (P2): Manifest update is ordered last (after all target commits). CRDT idempotency makes the non-atomic case safe — re-applying updates is a no-op.
