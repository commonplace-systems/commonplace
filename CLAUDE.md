# CLAUDE.md

## Project overview

<!-- state-projection:begin -->
Read STATE.md before scoping any work.
Rendered at: 2026-08-08T18:39Z.
<!-- state-projection:end -->

Commonplace is a CRDT document store built on Elixir/OTP. Every piece of data is a Y.js-compatible CRDT document identified by a UUID, organized in a tree via schema documents. The system provides branching (deep-copy fork), three-way merging, a Merkle-CRDT commit DAG, and bidirectional filesystem sync.

This is a port from a Rust version at `/home/jes/commonplace-rs/`. The Elixir version replaces yrs (Rust Y.js bindings) with yelixer (pure Elixir Y.js port), MQTT with Phoenix PubSub, and redb with CubDB.

## Architecture

Elixir umbrella with six apps:

- **yelixer** — Pure Elixir Y.js CRDT library. Wire-compatible with Yjs V1 binary protocol. Supports Text, Map, Array, XML types. Also maintained as a standalone repo at `commonplace-systems/yelixer` (transferred from `jes5199/` on 2026-08-08, along with `commonplace` and `commonplace-plan`). ⚠️ That standalone repo is **4.5 months stale** — last commit 2026-03-24, `encoding.ex` 1,012 lines vs the umbrella's 1,940. Re-converging it is CX-1mn4 → CX-fbah; do not treat it as a current mirror.
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
mix test apps/yelixer/test        # yelixer only (includes the 5,320-case yrs dataset)
mix test apps/commonplace/test    # core only
```

CI uses `--warnings-as-errors` — fix all compiler warnings before pushing.

## Key patterns

- **CommitStore access**: Use `CommitStoreClient` (not `CommitStore` directly) to preserve remote-serve capability.
- **Probing a live serve: an RPC to an unloaded module is a WRITE, not a read.** The serve runs in `:interactive` mode with its code path on the working tree's `_build/dev/lib`, so modules load lazily. `:erpc`/`:rpc` to a module the serve has not loaded yet **force-loads your current working tree's version into the live node** — including uncommitted code, and including functions that did not exist at deploy time. Measured 2026-08-05: a probe called a brand-new function on the live serve successfully, because the serve pulled it off disk. Consequences: a probe can silently change what the live serve executes; it can destroy the very condition you are testing; and "LOADED, md5 matches" about a module your own probe just touched is circular. **Rule: check `:code.is_loaded/1` first; if it is false, treat calling that module as a write and decide deliberately.** Prefer non-perturbing primitives — `:code.is_loaded/1` (code-server query) and `:erlang.get_module_info/2` (BIF reading the resident record) — over `module_info/1`, `Code.ensure_loaded?/1`, or `apply/3`, all of which auto-load. When a probe claims it does not perturb the node, prove it with a before/after `:code.all_loaded` count, not an argument. Reference implementations: `bin/cp-verify-deploy`, `Commonplace.VersionHandshake.resident_digest/1`.
- **BEAM distribution**: Set `COMMONPLACE_NODES=node1@host,node2@host` for clustering. Phoenix PubSub distributes automatically via `pg`. Catch-up sync uses CID set diff on node join. Use `import_commit` (not `create_commit`) when storing remote commits to avoid clobbering `:latest` pointer.
- **Schema mutations**: Use `Schema.add_file/3`, `Schema.add_directory/3`, `Schema.remove_entry/2`. Schema is a Yelixer.Doc with "entries" YMap.
- **Commits**: Use `CommitStore.create_chained_commit/3` for existing docs (chains to latest). Never create commits with `parent_id: nil` for existing documents.
- **Doc reconstruction**: Use `DocBuilder.reconstruct_doc/2` (full chain), `reconstruct_snapshot/2` (latest commit only), or `reconstruct_doc_at/3` (up to specific commit).
- **Merge**: `Merge.merge(source_uuid, target_uuid, store)` returns `{:ok, %MergeReport{}}`. Auto-renames on name collision (`.merge-conflict` suffix). Detects node_id replacements under unchanged filenames.
- **Trust / enforce mode**: Commits are Ed25519-signed. Gate A (`CommitStore.import_commit`) always verifies. Local write gate is staged via `:local_write_gate` (`COMMONPLACE_LOCAL_WRITE_GATE`), local read gate via `:local_read_gate` (`COMMONPLACE_LOCAL_READ_GATE`). `Trust.posture/0` reports the resolved knobs in one call.

## Issue tracking

**tix — the substrate's own tracker — is the authority. `bd` (beads) is a frozen ARCHIVE as of the 2026-08-05 cutover** (all 798 bd tickets migrated, ids preserved; design: commonplace-plan `docs/plans/2026-08-05-tix-authority-migration-design.md`). Issue prefix: CX.

- **Read/write tickets through the gated verb surface**: MCP `bd_*` tools when available (`bd_ready`, `bd_show`, `bd_create`, `bd_update`, `bd_close`, `bd_add_needs` — all route `Commonplace.ViewActionDispatch` / `Commonplace.Bd.CLI`), or the verbs directly on a serve (erpc to `ViewActionDispatch.dispatch/2` / `Bd.CLI` readers). ⚠️ **The CLI escript (`commonplace bd ...`) is BROKEN as of 2026-08-06 — do not use it**: the flock NIF cannot load inside an escript archive, so its embedded app boot dies at startup (CX-a449, P1; found by the deploy-#37 smoke). It fails closed — loud crash, cannot open anything — which is deliberate: its silent live-store open was the 2026-08-06 corruption incident's trigger. Until CX-a449 lands, use MCP tools or serve-side erpc.
- **Never `bd create`/`bd update`/`bd close`** — writes to the bd store deepen a divergence nothing reconciles anymore. Reading old bd data (closed-ticket history, comments pending CX-xmsd backfill) is harmless; `bd export` remains the archive read.
- ⛔ **BUT NEVER USE `bd` TO CHECK WHETHER A TICKET EXISTS.** `bd` is bound to the frozen archive and **cannot see any ticket filed since 2026-08-05** — measured 2026-08-08: **tix 854 issues, bd 798**, the 798 being the migration and the other 56 everything since. So `bd show CX-xxxx` returns a confident, well-formed **"no issue found" for tickets that demonstrably exist.** Two agents hit this within an hour; one was three lines from reporting six real tickets as fabricated, saved only by a positive control on a seventh. *(The old wording here — "reading old bd data is fine" — was true about HARM and silent about VALIDITY, and it licensed exactly that mistake. `bin/bd` now refuses the reflex; `CP_BD_ARCHIVE=1` opts into a deliberate archive read.)* To check existence, ask the store that holds it: MCP `bd_show`, or `Bd.Issue.show(root, id, CommitStoreClient)` by erpc on `commonplace_dev@commonplace`.
- Dependencies are `needs` refs on the ticket (cycle-gated via `ticket_add_needs`), NOT the retired `/bd/deps.json` blocks graph — its read/write surfaces now raise `Commonplace.Bd.RetiredGraphError` on purpose (CX-hrbn).
- ⚠️ The Claude Code beads plugin/hooks may still suggest `bd` commands at session start — that guidance is stale for THIS repo; tix is authoritative.

## Design docs

- `docs/plans/2026-03-21-commonplace-elixir-design.md` — overall system design
- `docs/plans/2026-03-22-filesystem-sync-design.md` — sync agent architecture (5 phases)
- `docs/superpowers/specs/2026-03-23-fork-as-dag-branch-design.md` — fork/merge design
- `docs/superpowers/specs/2026-03-24-sparse-sync-design.md` — multiple checkouts with per-entry agents
