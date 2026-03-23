# Branch Merge Design

> Design for CX-v4q: Merge across branches.
> Discussed 2026-03-23 in #loom between commonplace and commonplace-plan.

## Overview

Merge brings changes from a **source** branch into a **target** branch. The source is unchanged. This is directional, like `git merge`.

The ForkManifest (CX-89r) provides the provenance map: for every document in the forked branch, it records the original UUID and the fork-point commit. This is the foundation for merge.

## Prerequisites

- **ForkManifest** (CX-89r, done): tracks `new_uuid → {original_uuid, fork_point_commit}`
- **CommitStore**: stores commits with Yjs updates and parent chains
- **Yelixer state vectors**: `encode_state_as_update(doc, state_vector)` gives updates the other side hasn't seen

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

### Step 2: For Each Document in the Manifest

For documents that existed at fork time:

1. Load the source doc's current Yjs state
2. Reconstruct the fork-point state vector (from the fork_point_commit's Yjs update)
3. Compute the diff: `encode_state_as_update(source_doc, fork_point_state_vector)`
   - This gives "all Yjs updates in the source that happened after the fork"
4. Apply that update to the target doc: `apply_update(target_doc, diff)`
   - CRDT merge handles conflicts automatically — concurrent edits to the same text are resolved by client ID ordering

### Step 3: Handle New Documents (Post-Fork)

Documents created on the source branch after the fork have no counterpart in the target. These appear as new entries in the source's schema doc that weren't present at fork time.

**Action:** Copy the new document to the target (create new UUID, copy current content). This is a mini-fork of a single document.

### Step 4: Handle Deleted Documents

Documents deleted from the source branch (removed from schema) should be unlinked from the target schema too.

**Action:** Remove the entry from the target's schema doc. Do NOT delete the target's content doc — it may have its own edits that the user wants to keep. The GC reachability walk (CX-6rf) will eventually identify truly orphaned docs.

### Step 5: Schema Tree Merge

Schema docs are themselves CRDT documents (YMaps). Changes to the schema — new entries, removed entries, renames — can be merged the same way as content documents:

1. Reconstruct fork-point schema state vector
2. Compute schema diff (new entries since fork)
3. Apply to target schema

This handles directory structure changes (new subdirectories, moved files) automatically via CRDT merge.

### Step 6: Update Fork Point

After merge, update the ForkManifest's `fork_point_commit` for each document to the current source commit. This way, future merges only bring changes made since the last merge (incremental merge).

## __processes.json Handling

Same fork-safety filtering as fork (CX-89r):

- Entries with `"fork": "skip"` (or defaulting to skip) are **not merged** — they're branch-specific processes
- Entries with `"fork": "copy"` can be merged
- In practice, most process entries are branch-specific, so merge skips them
- Users manually configure processes on the target branch if needed

## Edge Cases

### Conflicting Schema Changes

If both source and target modified the same schema (e.g., both added a file with the same name but different UUIDs), CRDT merge resolves by keeping both entries. The YMap will have the last-writer-wins entry. This may need manual intervention — flag as a conflict for the user.

### Document Modified on Both Branches

CRDT handles this automatically. Both sets of edits are preserved. For text documents, concurrent insertions at the same position are ordered by client ID. No data is lost, though the result may need human review.

### Circular or Repeated Merges

The fork_point update (Step 6) prevents re-applying already-merged changes. Each merge advances the fork point, so the next merge only sees new changes.

## API

### Elixir Module

```elixir
Commonplace.Tree.Merge.merge(source_uuid, target_uuid, manifest, store)
# Returns {:ok, updated_manifest} or {:error, reason}
```

### CLI

```
commonplace merge <source-path> <target-path>
```

Looks up the ForkManifest to find the provenance mapping, performs the merge, and reports what changed.

## Future Considerations

- **Merge commits**: Record a commit on the target with metadata pointing to both pre-merge target commit and source commit as parents (DAG branching)
- **Conflict markers**: For schema conflicts (same name, different UUIDs), surface to the user
- **Three-way merge visualization**: Show fork-point state, source state, and target state side by side
- **Cherry-pick (CX-b70)**: Merge a single document's changes instead of the whole branch
