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
- **Agent access**: `commonplace_mcp` is an MCP server that gives an agent tool-level access to a live workspace over BEAM distribution. `commonplace_bots` runs an LLM tool-use loop on top of it, with call/token/wall-clock budgets, persona and charter documents, and a Telegram bridge.
- **MUD**: rooms, objects, and verbs are ordinary documents in the tree — this is the largest subsystem in the codebase. Citizen-authored "safe verbs" run sandboxed against a closed-by-default capability allowlist (the Facade), not against the raw store.
- **Issue tracking**: an on-substrate tracker (`bd`) where tickets, dependencies, and comments are documents rather than rows in an external database.
- **Trust**: commits are Ed25519-signed. `Commonplace.Trust.posture/0` reports the resolved read/write enforcement knobs for a running node.
- **Git bridge**: exports and syncs the document tree against a git remote.
- **Multi-node sync**: nodes clustered over BEAM distribution share a commit store via Phoenix PubSub, with CID-set diffing for catch-up on join.
- **Self-describing infrastructure**: some parts of the tree describe the system that's running it — presence documents track who's connected, process documents declare running OS/BEAM processes, projection documents compute derived views over other documents, and code documents hold executable behavior directly in the tree.

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
| `Commonplace.Trust` / `Commonplace.Trust.posture/0` | Resolved sign/verify and enforcement posture |
| `Commonplace.MUD.World.Facade` | Closed-by-default capability surface for citizen-authored verbs |
| `Commonplace.MUD.SafeVerb` | Sandboxed execution of citizen-authored verbs |
| `Commonplace.Bd.Ready` | On-substrate issue tracker: ready-work queries over ticket documents |
| `Commonplace.GitBridge.Server` | Sync between the document tree and a git remote |
| `Commonplace.Bots.Worker.Loop` | Agent-citizen tool-use loop (budgets, persona docs) |
| `Commonplace.MCP.Server` | MCP server exposing a live workspace to agent clients |

This table is a starting point, not the full picture — `commonplace`'s MUD subsystem alone is the largest body of code in the tree.

## Getting started

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Build the CLI (the escript lands in apps/commonplace_cli/)
mix escript.build --app commonplace_cli
CLI="$PWD/apps/commonplace_cli/commonplace_cli"

# Initialize a workspace — init creates .commonplace/ in the CURRENT directory
mkdir -p workspace && cd workspace && "$CLI" init

# Sync (watches for changes)
"$CLI" sync
```

⚠️ The CLI resolves its data directory from the current working directory
(`--data-dir` overrides). Run it from the workspace you mean to act on, never
from a directory that already holds someone else's `.commonplace/` — a second
opener on one store is how it gets corrupted.

## Design principles

- **BEAM fundamentals first**: GenServer-per-document, PubSub for dataflow, supervision trees for lifecycle. External interfaces come later.
- **Everything is documents, dataflow is the only verb**: Documents have UUIDs, are organized in a tree. Reachability from root = liveness.
- **Color channels** name communication semantics across the tree. Red (event logs), Magenta (ephemeral messages), and Green (exclusive locks) are built and have dedicated implementations. Blue (CRDT state) and Cyan (directed writes) are named in the design but don't yet have modules of their own.
- **Append-only CommitStore**: Data is never deleted. `rm -rf` on disk just removes schema entries; commit history preserves everything.
