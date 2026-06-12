# Bursar Dogfood Implementation Plan (Move #4, CX-tdkq.7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax.

**Goal:** Retire the `:global` MoveServer/TickBot split-brain hazard by integrating the
already-built green-token Bursar — architecture-review R7's single-node half.

**Architecture:** Bursar starts serve-only/opt-in and rides the CommitStore's existing
single-owner *designation* (convention-not-lock; inherits the residual two-serves risk,
fixes nothing — the cluster-arbiter fork stays R7-deferred). Remote nodes reach it through
a `BursarClient` dispatch seam identical to `CommitStoreClient` (`remote_node`
persistent_term → `GenServer.call({Bursar, node})`): zero `:global`, zero magenta change,
synchronous grant/deny. MoveServer is **retired** to per-path green tokens (canonical
sorted-path order kills livelock; release on all exit paths via try/after; short TTL is
only the crash net). TickBot becomes lease-based leader (60s TTL, renew at TTL/3,
renews **memory-only**); it stays an unconditional child but only ticks while holding the
lease, so bare-mix-run nodes degrade to fail-closed idle.

**Safety invariant (load-bearing):** *re-clock can only EXTEND a lease, never release it
early.* Acquire denies while any unexpired token exists + restart re-clock only pushes
expiry later ⇒ no double-hold ever; worst case is failover latency ≤ 1 extra TTL.
Pinned by the dead-holder + bursar-restart test (new holder within 2×TTL, never concurrent).

**Decisions ledger** (converged with commonplace-plan msgs 5182–5194, boss fence 5185/5192):

- **B1** Bursar features (acquire/ttl, release, transfer, renew, query, force_release,
  sweep) already exist — this move is pure integration.
- **B2** Serve-local single-node Bursar; `:global` Bursar explicitly off the table;
  cluster-wide arbiter = R7, deferred.
- **B3** BursarClient seam over magenta-reply-to (plan scrapped its own suggestion):
  reuse `CommitStoreClient.remote_node/0`; catch `:exit` → `{:error, :bursar_unavailable}`
  (fail-closed, Q6).
- **B4** Ephemeral/durable split: acquire/release/transfer **commit**; renew is
  **memory-only** (kills ~17k commits/day heartbeat bloat into the no-GC store). On
  Bursar restart, `load_state` re-clocks loaded tokens to now (full-TTL grace) — a dead
  holder's token lingers ≤1 extra TTL after a restart; acknowledged, acceptable.
- **B5** Two TTL regimes: move tokens SHORT (5s crash net, explicit release on all paths);
  tick lease LONG (60s, renew 20s).
- **B6** MoveServer retired to a plain module (its moduledoc called itself "v0 stand-in
  for the green channel"); token names = the two dir-schema UUIDs, sorted + deduped;
  deny → bounded retry then `{:error, :busy}` (retry policy lives with the caller).
- **B7** Deferred (beaded by commonplace worker): holder↔authenticated-identity binding
  (trust follow-up, P2), MUD Bot per-session `:global` names (P3).
- **B8** Opt-in gate `:bursar_on_boot` (default false) + workspace-gated, mirroring
  `:orchestrator_on_boot`; `commonplace serve` opts in.

**Live proof:** reproduce the memory'd incident — serve + bare `mix run` temp node joining
the cluster; `:global` orphaning gone; kill the TickBot leader → cross-node failover
within TTL through the seam. Committed artifact like prior demos.

---

### Task 1: Bursar lease semantics (renew memory-only + restart re-clock + invariant test)

**Files:** Modify `apps/commonplace/lib/commonplace/green/bursar.ex`,
`apps/commonplace/test/commonplace/green/bursar_test.exs`

- [x] Failing tests: (a) renew creates NO new commit on `__bursar.json`/`__bursar.log`;
      (b) restart re-clocks `acquired_at` to load time (token acquired with short TTL,
      sleep past expiry-if-not-re-clocked, restart bursar, token still held);
      (c) THE INVARIANT TEST: holder acquires `ttl:`, never renews, bursar restarts
      pre-expiry → competing acquire DENIED immediately post-restart (re-clock extended,
      no double-hold), then succeeds within 2×TTL of the restart.
- [x] Implement: `handle_call({:renew,...})` and magenta renew drop `persist_state` +
      `log_event` (memory + broadcast only); `load_state` re-clocks `acquired_at` to
      `DateTime.utc_now()`. Moduledoc states the invariant.
- [x] Focused suite green; commit.

### Task 2: BursarClient dispatch seam

**Files:** Create `apps/commonplace/lib/commonplace/green/bursar_client.ex`,
`apps/commonplace/test/commonplace/green/bursar_client_test.exs`

- [x] Failing tests: local delegation for all 7 verbs (against a named test Bursar);
      no-bursar-anywhere → `{:error, :bursar_unavailable}` for acquire/release/renew.
- [x] Implement: mirrors CommitStoreClient — `remote_node/0` from
      `CommitStoreClient.remote_node/0`; local → `GenServer.call(server, ...)`,
      remote → `GenServer.call({Bursar, node}, ...)`; try/catch `:exit` →
      `{:error, :bursar_unavailable}`.
- [x] Green; commit.

### Task 3: MoveServer → per-path green tokens (retire the singleton)

**Files:** Rewrite `apps/commonplace/lib/commonplace/mud/move_server.ex` (plain module),
modify `apps/commonplace/lib/commonplace/mud/world.ex`,
`apps/commonplace/lib/commonplace/application.ex` (drop child),
`apps/commonplace/test/commonplace/mud/move_server_test.exs`,
tick_bot/bot/player_session test setups (start a test Bursar instead of global MoveServer).

- [x] Failing tests: move acquires both dir tokens sorted/deduped and releases on success,
      on `{:error, :gone}`, and on raise (assert `query` → `:available` after each);
      contended path → bounded retry → `{:error, :busy}`; bursar unavailable →
      `{:error, :bursar_unavailable}` (fail-closed); existing move semantics preserved.
- [x] Implement; delete `@global_name` + GenServer machinery; update World.move docs.
- [x] Full MUD suite green; commit.

### Task 4: TickBot lease-based leadership

**Files:** Modify `apps/commonplace/lib/commonplace/mud/tick_bot.ex`,
`apps/commonplace/test/commonplace/mud/tick_bot_test.exs`

- [x] Failing tests: not-leader → `tick_now` returns `:not_leader`, no red events;
      leader ticks; renew fires when `now - last_renew > ttl/3` (assert via bursar
      `query` clock movement... renew is memory-only, assert via injected short TTL:
      leader survives past original expiry because renewal happened);
      failover: leader stops → second TickBot (different holder) becomes leader after
      TTL expiry and ticks; bursar unavailable → idle (`:not_leader`), no crash.
- [x] Implement: delete `@global_name` (local `__MODULE__` default); state gains
      `holder` ("tick_bot@#{node()}"), `lease_ttl_ms` (60_000), `last_renew`, `bursar`;
      `run_tick` gated on `ensure_leader`; renew cadence TTL/3 (first leadership
      observation → immediate renew, covers idempotent-acquire-stale-clock after a
      supervisor restart).
- [x] Green; commit.

### Task 5: Supervision + serve wiring

**Files:** Modify `apps/commonplace/lib/commonplace/application.ex`
(`bursar_children/0`), `config/config.exs`/`config/test.exs` if needed,
`apps/commonplace_cli/lib/commonplace/cli/serve.ex` (opt-in).

- [x] Failing test: `bursar_children/0` empty by default; non-empty when
      `:bursar_on_boot` true AND workspace root resolves.
- [x] Implement gate (mirror `orchestrator_children/0`); serve sets
      `:bursar_on_boot` before boot; confirm test env stays bursar-free.
- [x] Full core suite green (FOREGROUND — background runs hang on SandboxExecRunner
      orphans; check `PIPESTATUS[0]`); commit.

### Task 6: Live proof + checkpoint

**Files:** Create `demo/bursar_singletons/` (script + committed transcript),
checkpoint docs.

- [x] Demo: serve with bursar; bare `mix run` temp node joins (THE incident);
      show `:global.registered_names()` empty of MoveServer/TickBot, temp TickBot
      idle-not-leader; kill serve's TickBot → temp node acquires through the seam
      within TTL and ticks (cross-node failover). Capture transcript.
- [x] Commit artifact; report to boss; relay closes to commonplace worker.
