# CX-x8jk build brief: the CLI stops opening live stores — refuse or route

Ticket: CX-x8jk (tix, P1). Third of the incident trio, built after CX-2479
(flock exclusion) and CX-pm68 (refuse-to-boot) landed @8332f3c. With those
two in place this ticket's class downgrades from "a tool destroys the world"
to "a tool does something impolite" — this brief removes the impolite part
and the last parallel exclusion scheme.

## Context (do not re-derive)

2026-08-06 morning: `commonplace_cli bd ready`, run from the workspace
directory — DOCUMENTED usage — booted the escript's embedded commonplace
app, resolved the data dir from cwd to the LIVE `workspace/.commonplace`,
and opened the live commits CubDB beside the running serve. Post-CX-2479
that direct open loses to the serve's flock (crash with
`{:commits_store_locked, ...}` instead of corruption) — better, but still
wrong: the user asked a read question and got a crash, and the refusal
arrives from the store layer rather than from a tool that knows what the
user wanted.

## The defects to remove

1. **`Commonplace.CLI.acquire_db_lock/1`** (apps/commonplace_cli/lib/
   commonplace/cli.ex ~238): the old read-pid / `kill -0` liveness /
   take-over-on-stale prose-lock, over the SAME `commits.lock` file the
   flock now owns. Boss's framing, binding: it isn't a weaker lock, it is a
   lock with NO RELATIONSHIP to the real one — two independent exclusion
   schemes over one resource are worse than one, because each makes its
   holder feel safe. DELETE it (and `process_alive?`/`write_lock` if they
   lose their last caller). The flock in CommitStore.init IS the exclusion;
   the CLI gets its safety from routing/refusing BEFORE it ever reaches a
   direct open. Note its `write_lock` also clobbers the flock-holder's
   diagnostic hint content ("pid node" → bare pid) — deleting fixes that
   too.

2. **Cwd-resolved direct open with a serve up.** The CLI must implement
   refuse-or-route (the commonplace_mcp refuse-without-serve contract, one
   binary over):
   - **Detect** a running serve for the target data dir. Mechanics: the
     escript already has distribution (it joins the cluster today). Study
     how `bin/commonplace-mcp` / commonplace_mcp finds the serve node and
     what identifies "the serve FOR THIS data dir" (if node-name-only is
     what exists, that is acceptable for v1 — say so in a comment — but
     check whether the serve exposes its data_dir via an RPC-able function
     so dir identity can be confirmed; `Application.get_env(:commonplace,
     :data_dir)` on the serve is a read of an already-loaded app env —
     verify module residency rules don't bite: `Application` is always
     loaded).
   - **Route**: when the serve is reachable, `bd ready|blocked|list|show`
     and every other read go through the serve (erpc to the long-deployed
     readers / CommitStoreClient remote — study how CommitStoreClient's
     remote-serve capability is selected today). Writes (claim/close/
     comment wrappers) also route — they already dispatch verbs; verify
     they hit the SERVE's dispatcher, not a locally-booted one.
   - **Refuse**: when no serve is reachable AND the target dir's
     commits.lock flock is held (probe with `Sync.Flock.try_lock` +
     immediate unlock — non-destructive, verify that leaves the holder's
     lock intact — it does, flock is per-OFD, but PROVE it in a test:
     holder still holds after a probe), print the sanctioned-access
     refusal (reuse CX-2479's message text by calling a shared helper if
     one can live in commonplace core; do not duplicate the prose).
   - **Local open remains legal** ONLY when no serve is reachable and no
     flock is held — the genuine offline single-user case, which must keep
     working (people use the CLI against non-live checkouts).

3. **Loud data-dir provenance.** Whenever the CLI resolves its data dir
   from cwd (rather than an explicit flag/env), print ONE line to stderr
   naming the resolved path before touching anything. The incident's
   operator (me) would have stopped at "data dir: /home/jes/commonplace/
   workspace/.commonplace".

## Red-first tests

- Refusal path: a held flock (take one in the test) + no serve → CLI-layer
  read function returns/prints the named refusal, and the HOLDER'S LOCK IS
  INTACT afterwards (probe-then-unlock leaves no trace). Today's behavior
  to capture red-first: acquire_db_lock happily takes over when the pid in
  the file is dead-looking.
- Probe-harmlessness: holder holds; probe try_lock fails; holder still
  excludes a third opener. (Guards the probe from ever becoming an
  eviction.)
- Offline path: no serve, no flock → local open works exactly as today
  (fixture dir, not a live workspace).
- Routing: with a STUB serve — study whether a second node is feasible in
  tests (probably not; no distribution from tests is the standing
  constraint) — if not, test the DECISION function in isolation: given
  (serve_reachable?, flock_held?) the chosen mode is route/refuse/local
  per the table above, and the serve-reachable branch calls the remote
  path (verifiable with a Mox-style seam or a function head that takes the
  connector as an argument). State plainly in the report what is proven by
  test vs what needs the live smoke (I run the live smoke at deploy, from
  a SAFE cwd, per the incident constraint).

## Constraints (hard)
- Worktree only. NEVER touch workspace/.commonplace, never run the built
  escript against any real workspace, no distribution from tests (no
  Node.start in tests).
- Targeted test files only, one per invocation, captured to file, $?
  checked. NEVER bare `mix test`.
- `mix compile --warnings-as-errors` clean at the end. Also run the two
  scan guards (deny_site_scan_test, audit_rate_bucket_scan_test) and
  apps/commonplace/test/commonplace/store/commit_store_exclusion_test.exs
  (you are touching the other side of its contract).
- Commit small; do not push. The escript BINARY is not rebuilt by you —
  the coordinator rebuilds it at merge HEAD during deploy.
