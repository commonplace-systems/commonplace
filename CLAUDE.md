# CLAUDE.md

## Project overview

Commonplace is a CRDT document store built on Elixir/OTP. Every piece of data is a Y.js-compatible CRDT document identified by a UUID, organized in a tree via schema documents. The system provides branching (deep-copy fork), three-way merging, a Merkle-CRDT commit DAG, and bidirectional filesystem sync.

This is a port from a Rust version at `/home/jes/commonplace-rs/`. The Elixir version replaces yrs (Rust Y.js bindings) with yelixer (pure Elixir Y.js port), MQTT with Phoenix PubSub, and redb with CubDB.

## Architecture

Elixir umbrella with six apps:

- **yelixer** — Pure Elixir Y.js CRDT library. Wire-compatible with Yjs V1 binary protocol. Supports Text, Map, Array, XML types. Also maintained as a standalone repo at `jes5199/yelixer`.
- **commonplace** — Core library: CommitStore (CubDB), document tree (Schema, Fork, Merge, DocBuilder), sync agent, inode tracking.
- **commonplace_cli** — CLI escript for init, sync, checkout, branch, merge operations.
- **commonplace_web** — Phoenix LiveView UI with invite-token auth (two-phase: `require_auth` plug for dead-render + `on_mount ensure_authenticated` for the websocket mount), wiki/tree/outline/chat LiveViews, a browser MUD client (`MudLive`), and a bearer-token federation endpoint.
- **commonplace_mcp** — MCP server escript giving agents access to a live workspace over BEAM distribution; refuses to run without a running `commonplace serve` (the refuse-without-serve contract).
- **commonplace_bots** — Agent-citizen runtime: LLM tool-use loop with call/token/wall-clock budgets, persona/charter docs, Telegram bridge.

### Key data flow

1. Documents are Yelixer.Doc structs (Y.js CRDTs)
2. Changes are encoded as Yjs V1 binary updates via Yelixer.Encoding
3. Updates are stored as commits in the CommitStore (content-addressed Merkle DAG)
4. Schema documents map entry names to child UUIDs (tree structure)
5. Sync.Agent writes CRDT state to disk and reads disk changes back into CRDTs

### Storage

- **CommitStore**: CubDB at `.commonplace/commits/`. Append-only — data is never deleted.
- **Workspace**: Synced files live in the workspace directory. `.commonplace/` holds the database.
- **Shadow tracking**: `.commonplace-shadow/` directories hold hardlinks for stale write detection.

### MUD

Rooms, objects, and verbs are CRDT docs under the workspace tree (`lib/commonplace/mud/`). Citizen-authored verbs run as sandboxed "safe verbs" against the Facade allowlist (closed-by-default). Largest subsystem in core (~17k lines).

## Running tests

```bash
mix test                          # all apps
mix test apps/yelixer             # yelixer only (includes 5320 yrs dataset tests)
mix test apps/commonplace/test    # core only
```

CI uses `--warnings-as-errors` — fix all compiler warnings before pushing.

## Key patterns

- **CommitStore access**: Use `CommitStoreClient` (not `CommitStore` directly) to preserve remote-serve capability.
- **BEAM distribution**: Set `COMMONPLACE_NODES=node1@host,node2@host` for clustering. Phoenix PubSub distributes automatically via `pg`. Catch-up sync uses CID set diff on node join. Use `import_commit` (not `create_commit`) when storing remote commits to avoid clobbering `:latest` pointer.
- **Schema mutations**: Use `Schema.add_file/3`, `Schema.add_directory/3`, `Schema.remove_entry/2`. Schema is a Yelixer.Doc with "entries" YMap.
- **Commits**: Use `CommitStore.create_chained_commit/3` for existing docs (chains to latest). Never create commits with `parent_id: nil` for existing documents.
- **Doc reconstruction**: Use `DocBuilder.reconstruct_doc/2` (full chain), `reconstruct_snapshot/2` (latest commit only), or `reconstruct_doc_at/3` (up to specific commit).
- **Merge**: `Merge.merge(source_uuid, target_uuid, store)` returns `{:ok, %MergeReport{}}`. Auto-renames on name collision (`.merge-conflict` suffix). Detects node_id replacements under unchanged filenames.
- **Trust / enforce mode**: Commits are Ed25519-signed. Gate A (`CommitStore.import_commit`) always verifies. Local write gate is staged via `:local_write_gate` (`COMMONPLACE_LOCAL_WRITE_GATE`), local read gate via `:local_read_gate` (`COMMONPLACE_LOCAL_READ_GATE`). `Trust.posture/0` reports the resolved knobs in one call.

## Issue tracking

Uses `bd` (beads) — not markdown TODOs or external trackers. Issue prefix: CX.

```bash
bd ready              # find available work
bd show CX-xxx        # view issue
bd update CX-xxx --status=in_progress
bd close CX-xxx --reason="..."
```

⚠️ `bd ready` is currently an INCOMPLETE view of the work — bd and the substrate `/bd/` have diverged since the 2026-07-18 cutover and nothing reconciles them. Neither store alone answers "what is the work?". See CX-jhvn (measured 2026-08-05) for the exact items each side is missing.

## Design docs

- `docs/plans/2026-03-21-commonplace-elixir-design.md` — overall system design
- `docs/plans/2026-03-22-filesystem-sync-design.md` — sync agent architecture (5 phases)
- `docs/superpowers/specs/2026-03-23-fork-as-dag-branch-design.md` — fork/merge design
- `docs/superpowers/specs/2026-03-24-sparse-sync-design.md` — multiple checkouts with per-entry agents
