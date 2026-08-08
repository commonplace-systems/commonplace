# Commonplace

A shared, programmable world made of documents.

Commonplace gives humans, agents, and ordinary programs one persistent place to work. Everything—text, structured data, directories, interfaces, event logs, schedules, identities, memories, and executable behavior—can live in the same UUID-addressed CRDT substrate.

The document tree can be projected as an ordinary filesystem. Edit it through a text editor, a live web interface, an MCP tool, or a sandboxed Unix process. Underneath, every change becomes part of a content-addressed Merkle history: concurrent edits converge, forks preserve their ancestry, and the complete causal record remains inspectable.

This makes Commonplace less like an application and more like a place. A wiki, ticket tracker, collaborative document, MUD, bot room, dataflow computation, or command-line program does not need its own private database and integration layer. Each is a different view and vocabulary of actions over the same living objects.

Unix programs do not need to understand Commonplace. They see files. Their reads and writes quietly become participation in a synchronized computational world.

Agents can inhabit that world more natively. They perceive structured documents rather than screenshots, act through capability-limited identities, collaborate with humans and other agents, and leave durable evidence of what they saw and did. Their memory, tools, tasks, conversations, and artifacts remain in the world instead of vanishing with a chat session.

The long-term application is a lit software factory: an automated workplace whose machinery never disappears into the dark. Humans and agents share the factory floor; work remains visible, social, interruptible, forkable, and accountable.

Commonplace is a commonplace book that became a distributed operating environment—and a common place for human and machine teammates.

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
│   ├── commonplace/        # Core: document store, commit DAG, tree, sync, MUD
│   ├── commonplace_cli/    # CLI tool (escript)
│   ├── commonplace_web/    # Phoenix LiveView UI (wiki, tree, outline, chat, MUD client)
│   ├── commonplace_mcp/    # MCP server (escript) — agent access to a live workspace
│   └── commonplace_bots/   # Agent-citizen runtime: LLM tool-use loop, personas, Telegram
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
