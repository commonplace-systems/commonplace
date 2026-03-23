# Fork as DAG Branch

> Design for CX-9zu: Fork schema as edit in merkle tree, not new document.
> Brainstormed 2026-03-23 via Telegram.
> Supersedes `docs/plans/2026-03-23-branch-merge-design.md` (ForkManifest-based merge).

## Overview

A UUID is a branch name into a shared commit DAG. Fork creates new UUIDs that point at existing commits, then makes schema edit commits that remap child node_ids. No ForkManifest. Provenance is in the DAG itself.

This replaces the current deep-copy model where fork creates entirely new documents with separate commit chains and tracks provenance via a ForkManifest sidecar.

## Current Model (Being Replaced)

```
Target doc A:  c1 → c2 → c3       (UUID-A's chain)
Source doc A': c1' → c2' → c3'    (UUID-A' is a separate chain, content copied)
ForkManifest:  A' → {original: A, fork_point: c2}
```

- Fork deep-copies every document with new UUIDs
- ForkManifest tracks source→target provenance as a sidecar
- Merge must reconstruct fork-point state indirectly
- Key direction confusion (fork keys new→original, merge needs source→target)

## New Model

```
Doc A (target):  c1 → c2 → c3 → c4
                       ↑
Doc B (source):        c2 → c5 → c6
```

- B is a new UUID whose chain branches off A's history
- c5's `parent_id` = c2's `id` — the fork point is in the DAG
- c5 is a schema edit commit that remaps child node_ids to new forked UUIDs
- No ForkManifest needed — provenance is the shared commit prefix

## Fork Operation

Replaces the current `Fork.fork_directory/2` deep-copy.

### Step 1: Create branch points

For each document in the source tree (root schema, subdirectory schemas, leaf docs), create a new UUID and point it at the source's current latest commit:

```
CommitStore.set_latest(new_uuid, source_latest_commit_id)
```

No new commit is created — the new UUID is just a branch name pointing into the existing chain.

### Step 2: Schema edit commits (directories only)

For each directory schema in the tree, create a commit under the new UUID that edits the schema entries to point at the new forked child UUIDs.

The schema edit must be constructed as an **incremental CRDT edit** on the reconstructed source doc, not a fresh doc:

```elixir
# 1. Reconstruct the source schema by replaying the shared commit prefix
{:ok, source_schema} = reconstruct_doc(store, source_dir_uuid)

# 2. Make UUID remapping edits on the reconstructed doc
# (This uses the doc's existing CRDT state, so edits are incremental)
source_schema = Schema.remove_entry(source_schema, "file1.txt")
source_schema = Schema.add_file(source_schema, "file1.txt", new_child_uuid)

# 3. Encode the full state — when applied after the shared prefix,
#    this produces the correct result via CRDT idempotency
update = Encoding.encode_update(source_schema)
CommitStore.create_commit(store, new_dir_uuid, update, branch_point_commit_id)
```

This is a normal CRDT edit — the fork IS a schema mutation.

### Step 3: Leaf docs — branch-point commit

For leaf documents, create a trivial branch-point commit under the new UUID with the same content (a full-state encode of the reconstructed doc). This ensures `commit.doc_uuid` matches the new UUID for any code that inspects it, and avoids a consistency gap where `latest_commit(new_uuid).doc_uuid` returns the original UUID.

```elixir
{:ok, leaf_doc} = reconstruct_doc(store, source_leaf_uuid)
update = Encoding.encode_update(leaf_doc)
CommitStore.create_commit(store, new_leaf_uuid, update, source_latest_commit_id)
```

The first real edit on the forked branch then parents off this commit.

### Step 4: Process filtering (exception to Step 3)

If `__processes.json` exists, its branch-point commit from Step 3 is followed by an additional fork commit that edits the content to filter unsafe entries (same `Config.fork_behavior/1` rules as today). This is the one case where a leaf doc gets a content-modifying fork commit — the branch-point commit preserves the original content, and the filter commit removes unsafe entries on the forked branch only.

## Merge Simplification

### Finding the common ancestor

Walk both branches' parent chains until they converge on a shared commit:

```elixir
def common_ancestor(store, uuid_a, uuid_b) do
  log_a = CommitStore.commit_log(store, uuid_a) |> MapSet.new(& &1.id)
  log_b = CommitStore.commit_log(store, uuid_b)
  Enum.find(log_b, fn c -> MapSet.member?(log_a, c.id) end)
end
```

The common ancestor's state vector is the fork-point baseline. No indirect reconstruction needed.

Note: `commit_log` must be called with a high limit (default is 100). Alternatively, `is_ancestor?/3` already walks the chain without limits and could be adapted for common ancestor detection.

### Content merge

Same as today but simpler — the fork-point state vector comes from the common ancestor commit (which is on BOTH chains):

```elixir
{:ok, ancestor_doc} = reconstruct_doc_at(store, source_uuid, ancestor_commit.id)
ancestor_sv = BlockStore.state_vector(ancestor_doc.store)
diff = Encoding.encode_diff(source_doc, ancestor_sv)
Encoding.apply_update(target_doc, diff)
```

No need to know which chain the fork-point commit lives on — it's on both.

### Schema merge

The common ancestor schema has the SAME node_ids as both branches' fork-point state (because they share the commit). No UUID translation needed for the diff baseline. Schema diffing works naturally:

```elixir
ancestor_entries = Schema.entries(ancestor_schema)
source_entries = Schema.entries(current_source_schema)
diff = diff_schemas(ancestor_entries, source_entries)
```

Renames, adds, and removes are detected using the source branch's node_ids, which map 1:1 to the ancestor's node_ids (same lineage).

### Recursive subdirectory merge

Child docs are paired by **name** across the source and target schemas:

1. Walk both the source and target root schemas
2. For each name present in both: the source entry's node_id and target entry's node_id are a merge pair. Find their common ancestor, compute diff, apply.
3. For names only in source (added after fork): copy to target (create branch point + branch-point commit)
4. For names only in target (added after fork): leave untouched
5. For directory entries: recurse — walk the subdirectory schemas and repeat

Because every directory and leaf doc shares chains, the common ancestor for each pair is found by walking parent_ids until convergence. CX-spp (recursive schema diff) becomes trivial — just walk the schema tree and merge each subdirectory the same way.

### Same name, no shared ancestor (name collision)

When both branches independently added a doc with the same name after fork, the source and target entries have the same name but their node_id UUIDs share **no common ancestor** in the commit DAG. This is detected during child pairing:

1. Match entries by name across source and target schemas
2. For each matched pair, attempt to find common ancestor
3. If no common ancestor exists → **name collision conflict** (both branches created this independently)
4. Report as `{:name_collision, name, source_uuid, target_uuid}` — same conflict type as today

This replaces the current approach (comparing against fork-point entries to identify independent additions) with a more reliable DAG-based check: if two docs don't share history, they weren't forked from each other.

### Incremental merge

After merge, record the current source commit as the "last merged" point. Next merge uses this as the baseline instead of walking to the common ancestor. Stored in CommitStore as a dedicated key:

```elixir
CubDB.put(db, {:merge_point, target_uuid, source_uuid}, source_latest_commit_id)
```

On the next merge, load the merge point and use it as the diff baseline. If no merge point exists, fall back to common ancestor walk. The merge point is updated atomically at the end of merge (same crash-safety pattern as the current manifest update).

## CommitStore Changes

### New function: `set_latest/3`

```elixir
def set_latest(store, doc_uuid, commit_id)
```

Points a UUID at an existing commit without creating a new one. Used to establish branch points during fork.

Implementation: `CubDB.put(db, {:latest, doc_uuid}, commit_id)`

### `doc_uuid` field on Commit

Becomes historical/debugging provenance only. Add a comment:

```elixir
defstruct [
  :id,
  :doc_uuid,  # Historical: which UUID originally created this commit (debugging only)
  :parent_id,
  :update,
  :timestamp
]
```

No functional change — `commit_log` already walks parent_ids regardless of `doc_uuid`.

### No other CommitStore changes needed

`commit_log/2`, `get_commit/2`, `latest_commit/2`, `is_ancestor?/3` all work as-is since they walk parent chains, not doc_uuid associations.

## What This Eliminates

- **ForkManifest** — entirely. Provenance is in the DAG.
- **Manifest key direction confusion** — no manifest, no keys to get backwards.
- **Separate source/target fork-point tracking** — common ancestor is on both chains.
- **`reconstruct_doc_at` chain ambiguity** — fork-point commit is shared, found on either chain.
- **`collect_directory_uuids` workarounds** — recursive merge handles subdirs naturally.
- **Deep copy on fork** — no content duplication, just branch points + schema edits.
- **CX-spp** (recursive schema diff) — becomes trivial with per-doc common ancestors.
- **CX-o3i** (target fork-point tracking) — eliminated, common ancestor is unambiguous.

## Migration

The current `Fork.fork_directory/2` and `Merge.merge/4` would be rewritten. The ForkManifest module becomes unused. Existing forked trees (created with the old model) would need a migration path or compatibility layer.

Options:
- **Clean break**: old forks can't be merged with new code (acceptable if no production forks exist yet)
- **Compat layer**: detect ForkManifest presence and use old merge path

## Edge Cases

### CRDT client IDs

`Doc.new()` generates a random `client_id` each time. Branches reconstruct from the same commit prefix but new edits use distinct client IDs. No collision risk. CRDT merge handles concurrent edits deterministically.

### Common ancestor performance

Walking parent chains is O(depth). For long-lived branches, could optimize with a "last merged commit" pointer per UUID pair. Not needed for initial implementation.

### Content-addressed commit identity

Commits are content-addressed: `SHA256(parent_id || update)`. In theory, two forks from the same point with identical edits could produce the same commit ID. In practice, this cannot happen because schema edit commits contain different random UUIDs for the child remappings. Leaf branch-point commits also differ because `Encoding.encode_update` includes the doc's random client_id in the binary.

### Garbage collection

Commits are shared across branches. If a branch UUID is deleted (its `{:latest, uuid}` pointer removed), commits reachable only from that branch become orphaned. Any future GC must do reachability analysis across ALL `{:latest, *}` pointers, not just single-UUID chains.

## Prerequisites

None identified. The CRDT client ID concern was investigated and found to be a non-issue (random per `Doc.new()`).

## Related Issues

- **CX-spp** (recursive schema diff) — resolved by this design
- **CX-o3i** (target fork-point tracking) — resolved by this design
- **CX-5gr** (node_id replacement detection) — still relevant, orthogonal to this change
- **CX-6pp** (auto-rename on name collision) — still relevant, orthogonal
