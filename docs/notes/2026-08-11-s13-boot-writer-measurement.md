# S13 boot-writer measurement (zero fixes)

Date: 2026-08-11  
Branch/worktree: `disc/s13-boot-writer`  
Fixture: `apps/commonplace/test/commonplace/boot_writer_measurement_test.exs`

## Scope and method

This is a measurement only. Production code was not changed. The fixture uses two
independent tmp stores, seeds each while `local_write_gate: :off`, then sets:

```elixir
trust: %{accept_unsigned: false, trusted_identities: %{}}
local_write_gate: :enforce
```

Each store has a `root` file and a legacy-absent root schema: `chat` and `bd` are
present, and the root has no `workspace_profile` field. The already-existing chat
template and Bursar state/log entries are also seeded because those are the
idempotence conditions present in the live workspace. No node signing key or
public-key trust artifact is seeded; `NodeIdentity.signing_context/0` returns
`{:error, {:node_signing_key_absent, :prior_world_present}}`.

The driven startup sequence is the test-injectable equivalent of the relevant
application path, rather than a second `Commonplace.Application.start/2` inside an
already-running ExUnit application:

1. `Application.ensure_chat_template_if_workspace_present(store: tmp_store)`;
2. `MUD.Bootstrap.ensure_doc_manifests(tmp_store)`;
3. a Bursar child with the tmp store;
4. `GitBridge.Supervisor` reading a persisted one-mapping JSON file whose mount is
   the workspace root.

The fixture traces the concrete writer functions plus both CommitStoreClient create
verbs. A telemetry handler at `[:commonplace, :commit, :rejected, :local_trust]`
captures every denial from the exact tmp CommitStore PID. Trace and denial events
are correlated by writer PID, order, and document UUID; attribution below is not a
log-message inference.

## Part A: complete boot-reachable writer census

“Boot-reachable” includes synchronous init/ensure writes and writes reachable from
children's boot-started timers or immediate continues. A dash in the denial columns
means the path was silent in this fixture, not that the write would be accepted if
its activation condition were supplied.

| writer (file:line) | doc written | signing posture | denied under enforce? | matches live denial? |
|---|---|---|---|---|
| `Commonplace.Chat.TemplateBootstrap.ensure_template/2` (`apps/commonplace/lib/commonplace/chat/template_bootstrap.ex:85`; create sites 107, 113, 151, 192, 211, 217, 226, 235, 243, 255, 267) | Missing `chat` dir, root attach, `__template` schema, its five fresh leaves, or legacy `_compute` rewrite | No `signing_context` is passed at any site: unsigned | No: existing `chat/__template/_compute` made it idempotently silent | No; it is an unsigned boot writer the live three lines did not exercise |
| `Commonplace.MUD.Bootstrap.ensure_doc_manifests/1` (`apps/commonplace/lib/commonplace/mud/bootstrap.ex:345`, seed at 851/858) | Nineteen fixed-UUID parser/verb/help/template/world-meta docs when absent | Resolves node context per ensure and passes `signing_context: node_ctx`; if context resolution fails, it skips the create rather than writing unsigned | No: no node context, therefore zero attempted commits | No |
| `Commonplace.Green.Bursar.init/1` / `load_state/1` (`apps/commonplace/lib/commonplace/green/bursar.ex:326,685`; create sites 887-915) | Fresh `__bursar.json`, fresh `__bursar.log`, and root entries when absent; later Bursar events/state reuse those named docs | Resolves one node context at init and threads it via `sign_opts/1`; falls back to unsigned when unavailable | No: seeded named Bursar docs made init read-only | No; unsigned-capable, but silent live because its docs already existed |
| `Commonplace.MUD.TickBot` → Bursar (`apps/commonplace/lib/commonplace/mud/tick_bot.ex:116,144,178`) | Indirect Bursar state/log writes after the delayed tick lease acquisition | Bursar's node context, or unsigned fallback | No: the measurement window ended before its delayed first tick; ephemeral token state is not durable | No startup-line match |
| `Commonplace.GitBridge.Server.init/1` → `safe_create_presence/2` (`apps/commonplace/lib/commonplace/git_bridge/server.ex:65,75,356`) | One fresh `git-bridge.bot` presence doc, the mapped mount schema entry, then `activity="idle"` on the same fresh doc | Calls `Presence.create/5` and `Presence.set_activity/4` without opts, so both paths are unsigned | **Yes: all three fixture denials** | **Yes: exact live shape** |
| `Commonplace.Presence.create/5` and `set_activity/4` (`apps/commonplace/lib/commonplace/presence.ex:105-152,295-302`) | Fresh presence UUID at 143; mapped schema/root at 150; same fresh UUID at 302 | `SignedWrite.opts_for/2` receives no signing context from GitBridge; unsigned | **Yes: fresh, root, same fresh** | **Yes: `967027b6-…` is this fresh presence UUID class** |
| `Commonplace.GitBridge.Inbound` boot-started periodic cycle (`apps/commonplace/lib/commonplace/git_bridge/server.ex:133,193`; `git_bridge/inbound.ex:419-530,631,720`) | Imported/edited leaf docs and parent schema add/remove operations when a mapped repo has inbound changes | Attempts a persistent bridge-agent signing context (`inbound.ex:788-795`); empty opts/unsigned if unavailable | No: first cycle is delayed and the tmp repo had no inbound changes | No; conditional writer silent in the live startup excerpt |
| `Commonplace.SnapshotSweeper.handle_info/2` (`apps/commonplace/lib/commonplace/snapshot_sweeper.ex:131-149`) → `CommitStore.snapshot/2` (`store/commit_store.ex:654-663`) | Snapshot commit on every over-threshold existing doc | Bare `CommitStore.create_snapshot_commit`; no signing context, unsigned | No: first sweep is delayed (and test config normally disables it) | No; unsigned boot writer silent because no sweep fired/qualified |
| `Commonplace.Presence.Reaper.handle_info/2` (`apps/commonplace/lib/commonplace/presence/reaper.ex:104`; removal at 65-81) | Parent schema removal for stale root-level presence entries | Deliberately unsigned (`Presence.remove/3`) | No: 15-second first scan delay and no stale fixture presence | No; unsigned boot writer silent because its timer/condition did not fire |
| `Commonplace.Chat.ComputeRehydrator.handle_continue/2` (`apps/commonplace/lib/commonplace/chat/compute_rehydrator.ex:63-104`) → `ViewCompute` initial compute (`view_compute.ex:194-228,262`) → `CommandRouter.write` (`command_router.ex:410-451`) | Existing chat room `_view.xml` targets whose computed output differs | No context is passed through this boot path; target write is unsigned | No: fixture/live chat contains only `__template`, explicitly excluded at `compute_rehydrator.ex:126-128` | No; unsigned boot writer silent because there were no rehydratable rooms |
| `Commonplace.Reflog.CheckpointTimer` (`apps/commonplace/lib/commonplace/reflog/checkpoint_timer.ex:27,66-81`) → `Reflog.Snapshot` (`reflog/snapshot.ex:195-247`; create sites 375, 402, 415, 429, 560, 566, 582, 587) | Fresh `__reflog/serve` trees, schemas, and snapshot docs | Resolves one node context and threads it; explicitly falls back to unsigned if unavailable | No: `reflog_on_boot=false` | No; unsigned-capable but live knob was off |
| `Commonplace.MUD.GhostReaper.handle_info/2` (`apps/commonplace/lib/commonplace/mud/ghost_reaper.ex:89-99`, removal at 158-176) | Parent schemas of dead-in-both MUD presence ghosts | Requires node context; `run_once` aborts if absent; otherwise node-signed | No: delayed timer, no ghosts, and no node context in fixture | No |
| `Commonplace.Scheduler.Agent.init/1` (`apps/commonplace/lib/commonplace/scheduler/agent.ex:88-106`; mount sites 207-279; later commit 306-311) | Fresh `__system` schema + root attach, fresh `scheduler` doc + system attach; later schedule state | Every site is bare/unsigned | No: `scheduler_on_boot=false` | No; unsigned boot writer explicitly silent because live knob was off and `__system` stayed unmounted |
| `Commonplace.Trust.AuditCanary` (`apps/commonplace/lib/commonplace/trust/audit_canary.ex:104-131,161,267-291`) | Deterministic canary UUID on its delayed tick | Explicit `signing_context: :unsigned` by design | No: disabled in test config; production first tick is delayed by the interval | No; deterministic UUID, not a per-boot fresh UUID |
| `Commonplace.Trust.AuditDispatcher.persist_batch/4` (`apps/commonplace/lib/commonplace/trust/audit_dispatcher.ex:496-523`) | Deterministic trust-audit red-log UUID in response to denials | Node-signed only; if node context is absent it reports failure and does not attempt an unsigned commit | No denial of its own; fixture reported `no_node_signing_context` after the six measured denials | No |
| `Commonplace.Process.Orchestrator` first reconcile (`apps/commonplace/lib/commonplace/process/orchestrator.ex:140-169,232-248`; identity/delegation path 647-713) | Identity registry/capability docs for declared workers, plus any documents a declared process is authorized to mutate | Node-signed registrar/delegation plus agent context; missing node context can leave registrar opts empty | No: not an `Application` child under the reproduced Mode-B config, and no declared processes were seeded | No; conditional/arbitrary worker surface was silent |
| `Commonplace.Bd.Workspace.ensure_bd_dir/3` (`apps/commonplace/lib/commonplace/bd/workspace.ex:46-70`; create/attach sites 220-238 and `bd/schemas.ex`) | `bd` skeleton: named meta/deps docs and issues/labels schemas, plus parent schema entries | Threads caller opts; default call is unsigned | No: `bd` existed and no `Application.start/2` child or post-supervisor hook calls this lazy ensure | No; named seed candidate is **not actually invoked by Application boot** |
| `Commonplace.Workspace.Lock.init/1` (`apps/commonplace/lib/commonplace/workspace/lock.ex:80-96`) | Only `<data_dir>/serve.lock`; no CommitStore/schema/Issue write | Not applicable | No substrate denial possible | No |

No `Issue.update/5` call is reachable from the enumerated `Application.start/2`
children or its synchronous ensure hooks. Its production callers are command/action,
label, migration, and CLI paths, not boot paths. `Bd.Frontier.Server` can call the bd
ensure and write derived log/view docs, but it has no production start caller and is
not an Application child, so it is not a boot writer.

The remaining Application children are registries, PubSub/cluster/store/cache/task
supervisors, in-memory rate/session registries, empty dynamic supervisors, and idle
routers/dispatchers. They have no init/boot route to the requested commit/schema/
Issue mutation seams. Federation pull imports remote commits rather than calling the
local create/schema mutation seams counted by this brief. `publish_public_keys` and
`maybe_write_node_name` are node-local file writers, not document writers.

## Part B: denial attribution receipts

### Boot 1

Root: `e935e734-07c5-4b08-a413-bbfd5918b2e1`  
Fresh UUID absent from every seeded schema: `c86d9065-a47b-461d-9d2c-15d9d0a5bee0`

One traced PID (`#PID<0.727.0>`) produced this ordered call chain:

1. `GitBridge.Server.safe_create_presence/2`
2. `Presence.create/5`
3. `CommitStoreClient.create_commit/6` → fresh UUID → denial `:unsigned`
4. `CommitStoreClient.create_chained_commit/5` → root UUID → denial `:unsigned`
5. `Presence.set_activity/4`
6. `CommitStoreClient.create_chained_commit/5` → same fresh UUID → denial `:unsigned`

Telemetry receipts came from the exact tmp CommitStore PID `#PID<0.714.0>` in the
same target order: fresh, root, fresh.

### Boot 2

Root: `875c4b41-57f1-49fd-92ed-c20b4b7c7f53`  
Fresh UUID absent from every seeded schema: `0857b0ba-eb16-4121-96d8-a65f4cff64c7`

One traced PID (`#PID<0.741.0>`) produced the identical writer/call chain. Telemetry
from tmp CommitStore PID `#PID<0.728.0>` reported targets in the same order: fresh,
root, fresh. The fresh UUID differs from boot 1, demonstrating that this class
re-mints on every boot when enforce prevents the presence and schema entry from
landing.

## Same-shape statement and deviations

The final reproduction is the **same shape as live**: exactly three denials; one
workspace-root write; one freshly minted UUID denied twice; the fresh UUID appears
in no seeded schema; and the UUID is newly minted again on the second boot. The
root write is `Presence.create/5` attaching `git-bridge.bot` to the GitBridge mount
(the root mapping in this reproduction). The `967027b6-…` class is the GitBridge
presence document created at `Presence.create/5` and immediately written again by
`Presence.set_activity/4`.

Deviations from the live process are limited to the harness: it drove injectable
boot functions/children inside ExUnit rather than attempting to start a second
application, used new tmp stores and tmp git repos, and used synthetic UUIDs. The
fixture explicitly seeded the already-existing chat template and Bursar documents
to reproduce why those boot writers were silent. The ordinary test build succeeded
against the worktree dependency symlink. The separate dev/warnings gate did require
the brief's escape hatch after Phoenix tried to copy a template inside the read-only
symlink target: dependencies were copied to `/tmp/sol-s13-check.3V7TkJ/deps` and
the remaining checks used that `MIX_DEPS_PATH` plus
`MIX_BUILD_PATH=/tmp/sol-s13-check.3V7TkJ/build`. The third-party `uuid` dependency
emitted its pre-existing deprecated-`Bitwise` warning during the cold dependency
build; project code then passed `mix compile --warnings-as-errors` cleanly.

No fixes are proposed here.
