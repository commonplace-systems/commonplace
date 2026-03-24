# Commonplace

A CRDT document store where everything is a document with a UUID, organized in a tree. Documents sync between peers using Yjs-compatible CRDTs. Built on Elixir/OTP.

## What it does

- **Document tree**: Every piece of data is a CRDT document (text, map, array) identified by a UUID. Documents are organized in a tree structure via schema documents that map names to child UUIDs.
- **Commit DAG**: Each document has a Merkle-CRDT commit history (content-addressed commits storing Yjs update deltas). Gives tamper-evident history, branching, and merging.
- **Branching and merging**: Deep-copy fork creates a new tree with new UUIDs. Merge walks both schemas, diffs documents via CRDT, and reconciles changes (three-way merge with auto-rename on collision).
- **Filesystem sync**: Bidirectional sync between the CRDT store and the local filesystem. Edit files with any editor; changes sync into the CRDT and vice versa. Shadow hardlinks detect writes from stale file descriptors.
- **Yelixer**: Pure Elixir port of Y.js (CRDT library). Wire-compatible with Yjs V1 binary protocol. Supports Text, Map, Array, and XML types.

## Project structure

Elixir umbrella application:

```
commonplace/
├── apps/
│   ├── yelixer/            # CRDT library (pure Elixir Y.js port)
│   ├── commonplace/        # Core: document store, commit DAG, tree, sync
│   ├── commonplace_cli/    # CLI tool (escript)
│   └── commonplace_web/    # Phoenix LiveView UI
├── docs/
│   ├── plans/              # Design documents
│   └── superpowers/specs/  # Feature specs
└── workspace/              # Default sync directory
```

### Key modules

| Module | Purpose |
|--------|---------|
| `Yelixer.Doc` | Y.js document (Text, Map, Array CRDTs) |
| `Yelixer.Encoding` | Yjs V1 binary wire protocol encode/decode |
| `Commonplace.Store.CommitStore` | CubDB-backed persistent commit storage |
| `Commonplace.Tree.Schema` | Directory schema (name → UUID mapping) |
| `Commonplace.Tree.Fork` | Deep-copy branch with new UUIDs |
| `Commonplace.Tree.Merge` | Three-way merge with conflict detection |
| `Commonplace.Tree.DocBuilder` | Reconstruct documents from commit chains |
| `Commonplace.Sync.Agent` | Bidirectional filesystem sync |
| `Commonplace.Sync.InodeTracker` | Shadow hardlinks for stale write detection |

## Getting started

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Build the CLI
cd apps/commonplace_cli && mix escript.build

# Initialize a workspace
./commonplace init workspace/

# Sync (watches for changes)
cd workspace && ../commonplace sync
```

## Design principles

- **BEAM fundamentals first**: GenServer-per-document, PubSub for dataflow, supervision trees for lifecycle. External interfaces come later.
- **Everything is documents, dataflow is the only verb**: Documents have UUIDs, are organized in a tree. Reachability from root = liveness.
- **Color channels** define communication semantics: Blue (CRDT state), Cyan (directed writes), Red (event logs), Magenta (ephemeral messages), Green (exclusive locks).
- **Append-only CommitStore**: Data is never deleted. `rm -rf` on disk just removes schema entries; commit history preserves everything.
