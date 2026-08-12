# Production time-budget seam census — CX-11ms

Date: 2026-08-12. Round: DISC. Production and test code changes: **none**.
Telemetry events in scope: none.

## Outcome and scope

This is the measurement base requested by CX-11ms. It does not implement
deadline propagation. The destination constraints are carried only as the
classification frame: a future deadline originates at a boundary, propagates
remaining time, names the seam that expires, and lands at an existing seam.

The source scope is every umbrella application's production `lib/` tree:
429 `.ex`/`.exs` files under `apps/*/lib/`; tests are excluded from the
production table. The test-only known member and flake corpus are mapped after
the table. Counts below use this worktree as the baseline.

The production table has 272 rows: 195 `GenServer.call` constructs, 69 other
AST-enumerated waiting/transport constructs that are budgets or explicit
unbounded waits, and 8 hand-classified deadline/grace seams whose shape is not
a direct call in the AST family list. Thirty-six enumerated timer/receive sites
were classified as cadence, debounce, lease renewal, or zero-time mailbox drain
and are listed as exclusions rather than mislabeled as operation deadlines.

## Method — call sites, not literals

The primary instrument parsed every scoped source file with
`Code.string_to_quoted!/2` and walked its AST. It enumerated actual remote-call
nodes and their arity for `GenServer.call`, `GenServer.stop`, `Agent.get/update`,
`DynamicSupervisor.stop/terminate_child`, `:sys.get_state`, `:rpc.call`,
`:erpc.call`, `Task.yield`, `Process.send_after`, `Req` request functions,
`System.cmd`, and `receive ... after`. This is structurally different from a
timeout-literal grep: a bare `GenServer.call/2` is recorded from the call node
and classified as the invisible OTP `DEFAULT-5000` even though `5000` is absent
from the source.

The corrected AST baseline was 300 one-record-per-node findings. The relevant
population was 195 `GenServer.call` constructs: 175 bare call/2 sites, 19
call/3 sites, and one `&GenServer.call/2` capture used by dynamically invoked
remote calls. Source-context passes then classified timer messages, runtime
deadline arithmetic, Req options, CubDB options, and nesting. Installed Elixir
and copied dependency source supplied library defaults: `GenServer.call/2` and
`Agent.get/update` default to 5,000ms; `GenServer.stop` defaults to `:infinity`;
`DynamicSupervisor` management calls use `:infinity`; Req/Finch defaults are
5,000ms connect, 5,000ms pool checkout, and 15,000ms receive.

The broad textual pass was retained as a cross-check for dynamic expressions
and option plumbing, not used as the census instrument. It found the known
deadline arithmetic in flock, audit canary, MCP reply correlation, safe-verb
bounds, process shutdown grace, and the asynchronous view-compute kill timer.

### Row conventions

- **Basis `NONE`** means no in-repo comment or sizing commit declares why that
  number is appropriate. A language/library default is a source of the value,
  not a sizing basis.
- **Boundary origin** names the boundary family from which the call can descend.
  “All boundaries” means the shared API is reached from more than one of MCP,
  CLI, HTTP/session, federation, or background workers and no single origin can
  be assigned statically.
- **Position** is `BOUNDARY-adjacent` when the seam is in the transport/tool/CLI
  implementation itself; otherwise `MID-CHAIN`.
- **Callback-dependent** in the nesting column is an honest open set, not
  `NONE`: an injected module/function or a GenServer handler may cross further
  seams. Proven important chains are stated explicitly in the corpus map.

## Census, organized by boundary origin

Every row carries the six ruled fields: boundary origin; file:line; value and
declared basis; what it bounds; nested budgeted seams; position.

### `GenServer.call` population

| Boundary origin | File:line | Value · declared basis | What it bounds | Budgeted seams beneath it | Position |
|---|---|---|---|---|---|
| HTTP/LiveView | `apps/commonplace_web/lib/commonplace_web_web/write_rate_limit.ex:72` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:check_and_record, key}` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| HTTP/LiveView | `apps/commonplace_web/lib/commonplace_web_web/write_rate_limit.ex:76` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:config, opts}` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| HTTP/LiveView | `apps/commonplace_web/lib/commonplace_web_web/write_rate_limit.ex:80` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:key_count` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| HTTP/LiveView | `apps/commonplace_web/lib/commonplace_web_web/write_rate_limit.ex:84` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:sweep` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/ghost_reaper.ex:108` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:run_once` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/player_session.ex:131` | `10000`; explicit/dynamic; NONE unless named below | one synchronous request: `{:input, line}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/player_session.ex:134` | `5000`; explicit/dynamic; NONE unless named below | one synchronous request: `:drain_buffer` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/player_session.ex:142` | `10000`; explicit/dynamic; NONE unless named below | one synchronous request: `:room_snapshot` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/session_limit.ex:82` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:admit, principal, self()}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/session_limit.ex:92` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:attach, ref, pid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/session_limit.ex:101` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:release, ref}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/session_limit.ex:107` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:count` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/session_limit.ex:120` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:live_pids` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/tick_bot.ex:111` | `10000`; explicit/dynamic; NONE unless named below | one synchronous request: `:tick_now` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge.ex:274` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:pause` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge.ex:277` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:resume` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge.ex:284` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:tick_now` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge.ex:287` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:status` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge/poller.ex:155` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:offset` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge/poller.ex:158` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:poll_now` | callback-dependent; named proven chains in corpus map | BOUNDARY-adjacent |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/dispatcher.ex:168` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:subscribe_room, room_name, room_dir_uuid, messages_uuid, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/dispatcher.ex:174` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:unsubscribe_room, room_name}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/dispatcher.ex:179` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:registered_rooms` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/dispatcher.ex:274` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:register_autonomous_bot, strip_bot_suffix(name), dir_uuid, mud_root, cadence_ms, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/dispatcher.ex:283` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:unregister_autonomous_bot, strip_bot_suffix(name)}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/dispatcher.ex:288` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:registered_autonomous_bots` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/rate_limit.ex:86` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:acquire, room, bot}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/rate_limit.ex:89` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:release, room, bot}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/rate_limit.ex:92` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:record_post, room, bot}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/rate_limit.ex:95` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:config, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/rate_limit.ex:98` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:snapshot` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/rate_limit.ex:126` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:seed_from_history, room, posts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/agent.ex:167` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:sync_once` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/checkout_registry.ex:84` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:register, sync_dir, uuid, type}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/checkout_registry.ex:89` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:unregister, sync_dir}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/checkout_registry.ex:94` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:reroot, sync_dir, new_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/checkout_registry.ex:99` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:list` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/dir_agent.ex:90` | `60000`; explicit/dynamic; NONE unless named below | one synchronous request: `:sync_once` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/dir_agent.ex:379` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:sync_once` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/entry_agent.ex:114` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:sync_once` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/inode_tracker/registry.ex:23` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:track, inode_key, commit_id, doc_uuid, path}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/inode_tracker/registry.ex:28` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:lookup, inode_key}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/inode_tracker/registry.ex:33` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:shadow, inode_key, shadow_path, fingerprint}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/inode_tracker/registry.ex:38` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:list_shadows` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/inode_tracker/registry.ex:43` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:remove_shadow, inode_key}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/inode_tracker/registry.ex:56` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:shadow_for_path, path}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/node_sync.ex:95` | DEFAULT-5000 via `&GenServer.call/2` capture; INVISIBLE DEFAULT; NONE | one synchronous captured `(server, request)` call | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/schema_coordinator.ex:51` | `10000`; explicit/dynamic; NONE unless named below | one synchronous request: `{:mutate, store, mutation_fn}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| git-bridge timer/manual | `apps/commonplace/lib/commonplace/git_bridge/server.ex:62` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:pause` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| git-bridge timer/manual | `apps/commonplace/lib/commonplace/git_bridge/server.ex:65` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:resume` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| git-bridge timer/manual | `apps/commonplace/lib/commonplace/git_bridge/server.ex:68` | `60000`; explicit/dynamic; NONE unless named below | one synchronous request: `:sync_now` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| git-bridge timer/manual | `apps/commonplace/lib/commonplace/git_bridge/server.ex:71` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:status` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:131` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:running_processes` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:136` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:process_info` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox.ex:21` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:dir` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox.ex:25` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `{:exec, command, args}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox_exec_runner.ex:32` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:event_log_uuid` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox_exec_runner.ex:37` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:sandbox_dir` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox_exec_runner.ex:42` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:os_pid` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| reactive view/chat | `apps/commonplace/lib/commonplace/chat/loom_bridge.ex:118` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:pause` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| reactive view/chat | `apps/commonplace/lib/commonplace/chat/loom_bridge.ex:121` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:resume` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| reactive view/chat | `apps/commonplace/lib/commonplace/chat/loom_bridge.ex:129` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:tick_now` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| reactive view/chat | `apps/commonplace/lib/commonplace/chat/loom_bridge.ex:132` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:status` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| reactive view/chat | `apps/commonplace/lib/commonplace/view_compute.ex:181` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:recompute` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| reactive view/chat | `apps/commonplace/lib/commonplace/view_compute.ex:188` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:state` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| reflog CLI/timer | `apps/commonplace/lib/commonplace/reflog/checkpoint_timer.ex:23` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:checkpoint_now` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:96` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:insert_text, type_name, index, text}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:100` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:delete_text, type_name, index, len}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:104` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_text, type_name}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:108` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:encode_update` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:112` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:encode_diff, remote_sv}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:116` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:apply_update, update}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:120` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:state_vector` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:129` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:subscribe, self()}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared CRDT core (all boundaries) | `apps/yelixer/lib/yelixer/doc_server.ex:134` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:unsubscribe, self()}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/bd/frontier/server.ex:102` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:view_uuids` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/bd/frontier/server.ex:112` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:sync` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/black/pattern_compute.ex:169` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:recompute` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/black/pattern_compute.ex:174` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:refresh` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/black/pattern_compute.ex:179` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:state` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/command_router.ex:264` | `@fork_call_timeout`; named constant; in-file 30s deep-tree/load rationale | one synchronous request: `{:fork, source_uuid, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/command_router.ex:274` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:merge, source_uuid, target_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/command_router.ex:284` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:gc, root_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/command_router.ex:297` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:branch_set_sync, parent_uuid, name, true, commit_opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/command_router.ex:310` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:branch_set_sync, parent_uuid, name, false, commit_opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/command_router.ex:349` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:write, uuid, new_content, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex:32` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:add_edges, process_name, edges}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex:38` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:remove_edges, process_name}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex:44` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_graph` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex:50` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:find_cycles` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex:56` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:dependents, uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex:62` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:dependencies, process_name}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/red_log.ex:167` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:commit` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/tap.ex:16` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:observe, topic}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/dataflow/tap.ex:20` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:stop_observing, topic}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/gold/chain.ex:94` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:store_attestation, doc_uuid, att}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/gold/chain.ex:109` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:latest_attestation, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/gold/chain.ex:115` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:attestation_chain, doc_uuid, limit}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/green/bursar.ex:201` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:acquire, path, effective_holder, ttl_ms}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/green/bursar.ex:217` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:release, path, effective_holder}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/green/bursar.ex:227` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:query, path}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/green/bursar.ex:232` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:list_tokens` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/green/bursar.ex:237` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:force_release, path}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/green/bursar.ex:254` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:transfer, path, effective_from_holder, to_holder}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/green/bursar.ex:280` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:renew, path, effective_holder, new_ttl_ms}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/invariants/dispatcher.ex:104` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:status` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/presence/server.ex:45` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:uuid` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/presence/server.ex:46` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:identity_uuid` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/presence/server.ex:56` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_activity, activity}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/presence/server.ex:65` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_attributes, attrs}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/snapshot_sweeper.ex:113` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:stuck_docs` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:116` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_doc` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:125` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:current_namespace` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:127` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:apply_update, update}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:129` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:commit` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:132` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:create, type, name}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:135` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:insert_text, index, text}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:138` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_key, key, value}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:141` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:delete_key, key}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:144` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:push_items, values}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:148` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:insert_items, index, values}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:152` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:delete_items, index, length}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:155` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_content` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:158` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_content_type` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/document/server.ex:161` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_meta, key}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/tree/doc_cache.ex:88` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:invalidate, uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/tree/doc_cache.ex:97` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:size` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/tree/doc_cache.ex:106` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:uuids_by_access` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/tree/doc_cache.ex:115` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:clear` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/tree/doc_cache.ex:245` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:put, uuid, commit_id, doc}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared document/tree (all boundaries) | `apps/commonplace/lib/commonplace/tree/doc_cache.ex:260` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:bump_access, uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:585` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:create_commit, doc_uuid, update, parent_id, metadata, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:603` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:create_chained_commit, doc_uuid, update, metadata, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:694` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:write_snapshot_cas, doc_uuid, update, metadata, expected_parent_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:720` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:write_prebuilt_commit_cas, commit}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:759` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:put_built_commit, commit, expected_parent_id, genesis}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:790` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_trust_side_store` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:803` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_pending_imports` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:842` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:store_capability, cap}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:896` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:flush_execute_clean` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:907` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:store_revocation, rev}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1010` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:append_bd_issue_doc, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1021` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:append_bd_issue_doc_supersession, doc_uuid, reason}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1041` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_latest, doc_uuid, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1061` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:ensure_genesis, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1075` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:import_commit, commit, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1188` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_merge_point, target_uuid, source_uuid, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1198` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_last_merge_commit, target_uuid, source_uuid, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:2684` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_db` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:101` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:create_commit, doc_uuid, update, parent_id, metadata, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:135` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:latest_commit, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:144` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:create_commit, doc_uuid, update, parent_id, metadata, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:329` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:latest_commit, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:334` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:create_commit, doc_uuid, update, parent_id, metadata}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:347` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_commit, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:363` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:store_capability, cap}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:370` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_capability, cid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:379` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_execute_clean, fp, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:401` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:flush_execute_clean` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:425` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:store_revocation, rev}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:432` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_revocations, revoked_cid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:439` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:revocation_set_hash` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:447` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:latest_commit, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:457` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:commit_log, doc_uuid, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:470` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:commit_log_from, commit_id, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:480` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:all_doc_uuids` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:490` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:all_doc_uuids_bounded, limit}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:500` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:bd_issue_doc_uuids` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:510` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:append_bd_issue_doc, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:520` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:bd_issue_doc_supersessions` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:530` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:append_bd_issue_doc_supersession, doc_uuid, reason}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:540` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:is_ancestor, ancestor_id, descendant_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:550` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_latest, doc_uuid, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:560` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:commit_ids_for_doc, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:576` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:all_commit_ids_for_doc, doc_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:600` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:import_commit, commit, opts}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:622` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:find_common_ancestor, uuid_a, uuid_b}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:632` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_merge_point, target_uuid, source_uuid, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:642` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_merge_point, target_uuid, source_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:652` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set_last_merge_commit, target_uuid, source_uuid, commit_id}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store_client.ex:662` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get_latest_merge_head, target_uuid}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/pending_imports.ex:108` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:pending_count` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/secret_store.ex:27` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:set, name, value}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/secret_store.ex:32` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:get, name}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/secret_store.ex:37` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:list` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/secret_store.ex:42` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:delete, name}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/secret_store.ex:53` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:resolve_env, env}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/trust_side_store.ex:86` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:store_capability, cap}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/trust_side_store.ex:150` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `{:store_revocation, rev}` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/trust_side_store.ex:196` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:flush_execute_clean` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/trust_side_store.ex:295` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:get_db` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| write-gate/audit ops | `apps/commonplace/lib/commonplace/trust/audit_canary.ex:96` | `30000`; explicit/dynamic; NONE unless named below | one synchronous request: `:status` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| write-gate/audit ops | `apps/commonplace/lib/commonplace/trust/audit_canary.ex:101` | `timeout`; explicit/dynamic; NONE unless named below | one synchronous request: `:tick_now` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| write-gate/audit ops | `apps/commonplace/lib/commonplace/trust/audit_dispatcher.ex:163` | `DEFAULT-5000`; INVISIBLE DEFAULT; NONE | one synchronous request: `:status` | callback-dependent; named proven chains in corpus map | MID-CHAIN |
| write-gate/audit ops | `apps/commonplace/lib/commonplace/trust/audit_dispatcher.ex:174` | `timeout`; explicit/dynamic; NONE unless named below | one synchronous request: `:flush` | callback-dependent; named proven chains in corpus map | MID-CHAIN |

### Other enumerated waits and transports

Req rows carry the three distinct phase seams in one call-site row. The receive
budget is per received chunk, not a whole-request deadline, and retrying request
steps can multiply it.

| Boundary origin | File:line | Value · declared basis | What it bounds | Budgeted seams beneath it | Position |
|---|---|---|---|---|---|
| CLI entry | `apps/commonplace_cli/lib/commonplace/cli/access.ex:264` | 5000; NONE | `:rpc.call/5`: `serve_node ; Application ; :get_env ; [:commonplace, :data_dir] ; 5000` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| CLI entry | `apps/commonplace_cli/lib/commonplace/cli/cert_mint.ex:145` | connect DEFAULT-5000; pool DEFAULT-5000; receive DEFAULT-15000; Req/Finch defaults or explicit value; repo numeric basis NONE | `Req.post/2`: `endpoint ; [json: body]` | phase budgets are per checkout/connect/chunk; retries may multiply | BOUNDARY-adjacent |
| CLI entry | `apps/commonplace_cli/lib/commonplace/cli/ps.ex:67` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-0", to_string(pid_str)] ; [stderr_to_stdout: true]` | none; command itself is unbounded | BOUNDARY-adjacent |
| CLI entry | `apps/commonplace_cli/lib/commonplace/cli/serve.ex:285` | :infinity / unbounded; NONE | `System.cmd/3`: `"epmd" ; ["-names"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | BOUNDARY-adjacent |
| CLI entry | `apps/commonplace_cli/lib/commonplace/cli/serve.ex:289` | :infinity / unbounded; NONE | `System.cmd/3`: `"epmd" ; ["-daemon"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | BOUNDARY-adjacent |
| HTTP/LiveView | `apps/commonplace_web/lib/commonplace_web_web/live/tree_live.ex:82` | :infinity (DEFAULT); NONE | `GenServer.stop/1`: `socket.assigns.presence_pid` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MCP tool/session | `apps/commonplace_mcp/lib/commonplace_mcp.ex:455` | 5000; NONE | `:rpc.call/5`: `serve_node ; Application ; :get_env ; [:commonplace, :data_dir] ; 5000` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MCP tool/session | `apps/commonplace_mcp/lib/commonplace_mcp.ex:504` | :infinity (DEFAULT); NONE | `:rpc.call/4`: `serve_node ; Application ; :get_env ; [:commonplace, :mud_full_citizenship]` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MCP tool/session | `apps/commonplace_mcp/lib/commonplace_mcp.ex:716` | 5000; NONE | `GenServer.stop/3`: `pid ; :normal ; 5000` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MCP tool/session | `apps/commonplace_mcp/lib/commonplace_mcp.ex:735` | 5000; NONE | `GenServer.stop/3`: `pid ; :normal ; 5000` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MCP tool/session | `apps/commonplace_mcp/lib/commonplace_mcp/crdt_tools.ex:175` | dynamic `remaining` from interface deadline; NONE | `receive_after`: `(remaining -> in_band_error( "tool '#{ctx[:tool_name]}' timed out after #{deadline_total_ms(deadline, remaining)}ms (target_path=#{ctx[:target_path]})" ))` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MCP tool/session | `apps/commonplace_mcp/lib/commonplace_mcp/tools/bd_route.ex:49` | rpc_timeout(); named dynamic constant; in-file fail-fast rationale | `:rpc.call/5`: `node ; mod ; fun ; args ; rpc_timeout()` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MCP tool/session | `apps/commonplace_mcp/lib/commonplace_mcp/tools/bot_route.ex:66` | rpc_timeout(); named dynamic constant; in-file fail-fast rationale | `:rpc.call/5`: `node ; Bot ; fun ; args ; rpc_timeout()` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/ghost_reaper.ex:226` | 3000; NONE | `:sys.get_state/2`: `pid ; 3000` | single wait; callback/target-dependent | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/player_session.ex:144` | :infinity (DEFAULT); NONE | `GenServer.stop/2`: `pid ; :normal` | single wait; callback/target-dependent | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/safe_verb/bounds.ex:55` | dynamic app-env (default 3000); named default; bounded-code rationale | `receive_after`: `(timeout_ms -> Process.exit(pid, :kill) Process.demonitor(mon_ref, [:flush]) receive do {^ref, :result, _late_result} -> :ok after 0 -> :ok end {:error, :timeout})` | single wait; callback/target-dependent | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/session_view_registry.ex:42` | DEFAULT-5000; INVISIBLE DEFAULT; NONE | `Agent.get/2`: `__MODULE__ ; &Map.get(&1, identity_uuid)` | single wait; callback/target-dependent | MID-CHAIN |
| MUD HTTP/session/timer | `apps/commonplace/lib/commonplace/mud/session_view_registry.ex:48` | DEFAULT-5000; INVISIBLE DEFAULT; NONE | `Agent.update/2`: `__MODULE__ ; &Map.put(&1, identity_uuid, view_uuid)` | single wait; callback/target-dependent | MID-CHAIN |
| Mix-task CLI | `apps/commonplace/lib/mix/tasks/commonplace.mixed_plane_scan.ex:111` | :infinity; NONE | `:erpc.call/5`: `serve_node ; MixedPlaneHistory ; :run ; [Keyword.put(opts, :mode, :live)] ; :infinity` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| Mix-task CLI | `apps/commonplace_bots/lib/mix/tasks/bots.tail.ex:130` | 5000; NONE | `:rpc.call/5`: `node_name ; Commonplace.Bots.Dispatcher ; :registered_rooms ; [] ; 5000` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| Mix-task CLI | `apps/commonplace_bots/lib/mix/tasks/bots.tail.ex:144` | 5000; NONE | `:rpc.call/5`: `node_name ; Commonplace.Bots.Activity ; :list ; [uuid, Commonplace.Store.CommitStoreClient] ; 5000` | single wait; callback/target-dependent | BOUNDARY-adjacent |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge/poller.ex:309` | connect DEFAULT-5000; pool DEFAULT-5000; receive dynamic `(poll_s + 10) * 1000`; Req/Finch defaults or explicit value; repo numeric basis NONE | `Req.get/2`: `url ; opts` | phase budgets are per checkout/connect/chunk; retries may multiply | BOUNDARY-adjacent |
| Telegram ingress/timer | `apps/commonplace_bots/lib/commonplace/bots/telegram_bridge/transport/telegram.ex:192` | connect DEFAULT-5000; pool DEFAULT-5000; receive 15000; Req/Finch defaults or explicit value; repo numeric basis NONE | `Req.post/2`: `url ; opts` | phase budgets are per checkout/connect/chunk; retries may multiply | BOUNDARY-adjacent |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/demo_session.ex:116` | DEFAULT-5000; INVISIBLE DEFAULT; NONE | `Agent.get/2`: `@name ; & &1` | single wait; callback/target-dependent | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/demo_session.ex:57` | DEFAULT-5000; INVISIBLE DEFAULT; NONE | `Agent.update/2`: `@name ; fn _ -> demo end` | single wait; callback/target-dependent | MID-CHAIN |
| bot runtime | `apps/commonplace_bots/lib/commonplace/bots/worker/client.ex:59` | connect DEFAULT-5000; pool DEFAULT-5000; receive 60000; Req/Finch defaults or explicit value; repo numeric basis NONE | `Req.post/2`: `endpoint ; [ json: body, headers: [{"x-api-key", key}, {"anthropic-version", @anthropic_version}], receive_timeout: 60000 ]` | phase budgets are per checkout/connect/chunk; retries may multiply | MID-CHAIN |
| federation pull | `apps/commonplace/lib/commonplace/federation/pull_client.ex:176` | connect DEFAULT-5000; pool DEFAULT-5000; receive DEFAULT-15000; Req/Finch defaults or explicit value; repo numeric basis NONE | `Req.request/1`: `opts` | phase budgets are per checkout/connect/chunk; retries may multiply | BOUNDARY-adjacent |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/checkout_registry.ex:357` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `Commonplace.Checkout.Supervisor ; pid` | single wait; callback/target-dependent | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/dir_agent.ex:158` | :infinity (DEFAULT); NONE | `DynamicSupervisor.stop/1`: `state.supervisor` | single wait; callback/target-dependent | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/dir_agent.ex:428` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `state.supervisor ; pid` | single wait; callback/target-dependent | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/dir_agent.ex:95` | :infinity (DEFAULT); NONE | `GenServer.stop/2`: `pid ; :normal` | single wait; callback/target-dependent | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/entry_agent.ex:119` | :infinity (DEFAULT); NONE | `GenServer.stop/2`: `pid ; :normal` | single wait; callback/target-dependent | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/sync_loop.ex:108` | :infinity (DEFAULT); NONE | `GenServer.stop/1`: `state.agent_pid` | single wait; callback/target-dependent | MID-CHAIN |
| git-bridge timer/manual | `apps/commonplace/lib/commonplace/git_bridge/git.ex:205` | :infinity / unbounded; NONE | `System.cmd/3`: `"git" ; ["merge-base", "--is-ancestor", ancestor, descendant] ; [cd: repo_dir, stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| git-bridge timer/manual | `apps/commonplace/lib/commonplace/git_bridge/git.ex:271` | :infinity / unbounded; NONE | `System.cmd/3`: `"git" ; args ; [cd: repo_dir, stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:274` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-TERM", "#{pid}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:275` | :infinity / unbounded; NONE | `System.cmd/3`: `"pkill" ; ["-TERM", "-P", "#{pid}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:285` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-9", "#{pid}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:286` | :infinity / unbounded; NONE | `System.cmd/3`: `"pkill" ; ["-9", "-P", "#{pid}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:292` | 2000; NONE | `GenServer.stop/3`: `info.pid ; :shutdown ; 2000` | single wait; callback/target-dependent | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:353` | 5000; NONE | `GenServer.stop/3`: `pid ; :shutdown ; 5000` | single wait; callback/target-dependent | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox.ex:30` | :infinity (DEFAULT); NONE | `GenServer.stop/1`: `pid` | single wait; callback/target-dependent | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox.ex:72` | :infinity / unbounded; NONE | `System.cmd/3`: `command ; args ; [cd: state.sandbox_dir, stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox.ex:81` | 2000; NONE | `GenServer.stop/3`: `state.sync_pid ; :shutdown ; 2000` | single wait; callback/target-dependent | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox_exec_runner.ex:229` | :infinity / unbounded; NONE | `System.cmd/3`: `"pgrep" ; ["-P", "#{os_pid}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox_exec_runner.ex:244` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; [sig, "#{p}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox_exec_runner.ex:259` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-0", "#{pid}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:110` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-0", "--", "-#{pid_str}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:112` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-0", pid_str] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:116` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-TERM", "--", "-#{pid_str}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:119` | :infinity / unbounded; NONE | `System.cmd/3`: `"pkill" ; ["-TERM", "-P", pid_str] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:120` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-TERM", pid_str] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:125` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-9", "--", "-#{pid_str}"] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:126` | :infinity / unbounded; NONE | `System.cmd/3`: `"pkill" ; ["-9", "-P", pid_str] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:127` | :infinity / unbounded; NONE | `System.cmd/3`: `"kill" ; ["-9", pid_str] ; [stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:80` | 1000; NONE | `GenServer.stop/3`: `pid ; :shutdown ; 1000` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/black/pattern_compute_supervisor.ex:75` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `__MODULE__ ; pid` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/black/pattern_compute_supervisor.ex:97` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `__MODULE__ ; child_pid` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/chat/chat_view_compute_supervisor.ex:108` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `__MODULE__ ; pid` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/chat/chat_view_compute_supervisor.ex:130` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `__MODULE__ ; child_pid` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/chat/onramp_supervisor.ex:121` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `__MODULE__ ; child_pid` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/chat/onramp_supervisor.ex:97` | :infinity (library-internal); NONE | `DynamicSupervisor.terminate_child/2`: `__MODULE__ ; pid` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/projection/mixed_plane_history_fixture.ex:29` | :infinity (DEFAULT); NONE | `GenServer.stop/1`: `pid` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/proto_chit.ex:147` | :infinity / unbounded; NONE | `System.cmd/3`: `real_git ; args ; [cd: repo, stderr_to_stdout: true]` | none; command itself is unbounded | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/version_handshake.ex:167` | @rpc_timeout; NONE | `:rpc.call/5`: `node ; mod ; :module_info ; [:md5] ; @rpc_timeout` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/version_handshake.ex:330` | @rpc_timeout; NONE | `:rpc.call/5`: `node ; __MODULE__ ; :resident_digest ; [@apps] ; @rpc_timeout` | single wait; callback/target-dependent | MID-CHAIN |
| shared core (multiple boundaries) | `apps/commonplace/lib/commonplace/view_compute.ex:395` | dynamic `state.compute_timeout_ms` (default 10000); named default; in-file kill rationale | `Process.send_after/3`: `self() ; {:compute_timeout, ref} ; state.compute_timeout_ms` | single wait; callback/target-dependent | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:1620` | 100; NONE | `GenServer.stop/3`: `pid ; :normal ; 100` | single wait; callback/target-dependent | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/store/commit_store.ex:3180` | timeout_ms; NONE | `Task.yield/2`: `task ; timeout_ms` | single wait; callback/target-dependent | MID-CHAIN |

### Deadline/grace seams found by source-context classification

| Boundary origin | File:line | Value · declared basis | What it bounds | Budgeted seams beneath it | Position |
|---|---|---|---|---|---|
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/flock.ex:48` | dynamic argument, default 30,000ms; named constant, numeric basis NONE | exclusive-lock acquisition retry loop | unbounded NIF call attempts; 10ms retry sleeps | MID-CHAIN |
| filesystem sync / cluster catch-up | `apps/commonplace/lib/commonplace/sync/flock.ex:56` | dynamic argument, default 30,000ms; named constant, numeric basis NONE | shared-lock acquisition retry loop | unbounded NIF call attempts; 10ms retry sleeps | MID-CHAIN |
| write-gate/audit ops | `apps/commonplace/lib/commonplace/trust/audit_canary.ex:299` | dynamic `state.bound_ms`, default 5,000ms; named constant, “denial round-trip” rationale | repeated observation of both audit mechanisms | bare audit-dispatcher status calls, each independently DEFAULT-5000; original remaining time is not passed to them | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sandbox_exec_runner.ex:194` | named 5,000ms TERM grace, then 1,000ms KILL grace; cleanup rationale, numeric basis NONE | polling all descendant OS pids dead | unbounded `System.cmd` probes/signals, so the stated grace is not a hard chain bound | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/orchestrator.ex:280` | named 5,000ms grace; NONE | fixed wait between TERM and KILL | unbounded `System.cmd` signals before/after and explicit GenServer-stop waits beneath | MID-CHAIN |
| process CLI/orchestrator | `apps/commonplace/lib/commonplace/process/sweep.ex:123` | dynamic `grace_ms`, default 5,000ms, plus fixed 500ms post-KILL wait at line 128; NONE | prior-generation OS cleanup | unbounded `System.cmd` probes/signals; not a hard chain bound | MID-CHAIN |
| shared store (all boundaries) | `apps/commonplace/lib/commonplace/projection/mixed_plane_history.ex:180` | explicit `timeout: :infinity` at line 193; deliberate resumable scan | every async-stream document scan | each worker may cross shared-store call seams | MID-CHAIN |
| write-gate/audit ops | `apps/commonplace/lib/commonplace/trust/audit_canary.ex:67` | default 5,000ms bound; denial-round-trip rationale | default supplied to the line-299 deadline seam | same nested status-call defaults described at line 299 | MID-CHAIN |

## Timer and option classifications that did not become deadline rows

The AST sweep found 32 `Process.send_after/3` sites. One enforces an operation
timeout (`view_compute.ex:395`) and is in the table. The other 31 schedule
cadence, debounce, polling, TTL sweep, heartbeat, or delayed work; they do not
bound an in-flight operation. It found seven `receive ... after` sites: MCP
reply correlation and safe-verb execution are deadline rows; the remaining
five are lease-renew cadence, CLI polling, or zero-time mailbox drains.

No `:timer` call site was present. Positive control for that negative family:
the same AST/timer pass found all 32 `Process.send_after/3` nodes and the
view-compute timeout member. No production `Task.await`, `Task.await_many`, or
`Task.await/1` default was present; positive control: the pass found
`Task.yield/2` at `commit_store.ex:3180` and the separately optioned
`Task.async_stream` at `mixed_plane_history.ex:180`.

No project CubDB option expressed a call timeout. The option sweep did find
the positive-control options `auto_file_sync` and `auto_compact` at
`commit_store.ex:1663-1664` and the salvage open at line 1113, so this is not a
wrong-path empty grep. CubDB's dependency-internal calls are a named
cross-application blind spot below.

## Corpus mapping and proven nesting

| Corpus member | Boundary origin | Seam(s) crossed or exposed | Nesting / conclusion |
|---|---|---|---|
| ticket creation | MCP tool, then serve-side verb dispatch | outer dynamic 30,000ms RPC at `apps/commonplace_mcp/lib/commonplace_mcp/tools/bd_route.ex:49`; inner invisible DEFAULT-5000 at `apps/commonplace/lib/commonplace/store/commit_store.ex:759` | The create builds several documents sequentially. Each caller-side commit build lands through `put_built_commit`, whose bare call has its own 5s budget; all are beneath one 30s RPC. The id is minted before those writes. This is the known orphan-minting member and was found. |
| Bursar durable acquire | MUD/tool/background caller into shared Bursar | outer invisible DEFAULT-5000 at `apps/commonplace/lib/commonplace/green/bursar.ex:201`; inner invisible DEFAULT-5000 at `apps/commonplace/lib/commonplace/store/commit_store.ex:759` | A durable acquire can persist the table and append its red-log event; each write can land through the inner `put_built_commit` seam. The outer 5s call does not propagate remaining time. Known production member found. |
| S18 sized inner bound | test only, directly into Bursar | `apps/commonplace/test/commonplace/green/bursar_test.exs:576`, explicit 30,000ms inside an outer 600,000ms ExUnit timeout | This is test-side only and does not alter the production API. It replaced the crossed production Bursar 5s call for the 200-operation scale arm. Known member found. |
| room-visibility look flake | MUD PlayerSession test | production candidate `apps/commonplace/lib/commonplace/mud/player_session.ex:131`, explicit 10,000ms input call; test also has the inherited 60,000ms ExUnit ceiling and fixed output sleeps/drains | Available gate history says only “look under concurrent-build load; 13/0 isolated” and does not preserve the failure exception. Therefore this census cannot honestly distinguish the 10s production call from the test's outer/fixed windows. Attribution is **stopped as indeterminate**, not silently assigned. |
| sandbox file-flow flake | sandbox test | test-side fixed 400ms observation window in `apps/commonplace/test/commonplace/process/sandbox_test.exs:141`; production `Sandbox.exec` has 30,000ms at `apps/commonplace/lib/commonplace/process/sandbox.ex:25`, but the command had already returned | The failed property was eventual CRDT visibility after command completion. It crossed a test-side fixed window, not the production exec-call seam. Later condition-driven coverage is a separate test-side remedy. |
| capture-rate flake | audit performance/test enclosure | test-side wall-clock verdict; production audit status calls are DEFAULT-5000 and flush is dynamic at `apps/commonplace/lib/commonplace/trust/audit_dispatcher.ex:163-174`, but the recorded full-core failure was a measured ratio/noise verdict | The preserved gate report names a load-sensitive wall-clock performance arm and says it was green isolated. No production timeout exception was reported. Classified test-side measurement budget only. |
| salvage fixture flake | CommitStore test fixture | deterministic `/tmp` path, no timeout | Live tix was read from a snapshot of the sanctioned workspace store. Its title/body say stale rows from a prior run changed expected 20 to 30 and fresh temp environments are green. Cross-run fixture contamination; no production time seam crossed. |
| zone-setup flake | MUD fixture setup | inherited 60,000ms ExUnit budget over many synchronous commit writes; each write can cross `commit_store.ex:759` DEFAULT-5000 | The available report does not preserve an inner `GenServer.call` timeout. The named failure was setup duration and green isolation, so the observed crossing is the test-side outer budget; the production 5s write seam is nested exposure, not proven as the firing seam. |

The room-visibility correction is deliberately visible: an earlier working
classification treated it as the production 10s call from proximity alone.
The retained evidence does not include the exception shape, so that claim was
withdrawn and the row now says indeterminate.

## Falsifiability controls

### 1. Known members

All three positive controls were found:

- ticket creation's inner bare `CommitStore.put_built_commit` call at
  `commit_store.ex:759`: invisible DEFAULT-5000;
- Bursar's production call at `bursar.ex:201` and its nested landing through
  `commit_store.ex:759`: invisible DEFAULT-5000 members;
- the S18 test's explicit 30,000ms direct Bursar call at
  `bursar_test.exs:576`, inside its 600,000ms outer budget.

The run is therefore not void on the positive-control criterion.

### 2. Seeded plant, found then removed

After recording the corrected 300-node AST baseline, the scratch file
`apps/commonplace/lib/cx_11ms_seeded_plant.ex` was added with:

```elixir
GenServer.call(x, y, 1_234)
```

The identical sweep rose from 300 to 301 records and emitted:

```text
apps/commonplace/lib/cx_11ms_seeded_plant.ex:2  GenServer.call/3  x || y || 1234
```

The file was removed. The post-removal sweep returned to 300 records and was
byte-for-byte equal to the baseline; exact path and exact planted-row absence
checks both passed. No plant remains in the worktree.

### 3. Coverage and structural blind spots

This census can see literal, named-constant, runtime-expression, and invisible
default budgets when the relevant call node is present in the scoped source.
It cannot prove a closed runtime call graph. Named blind spots are:

- dynamic dispatch through injected modules/functions (`apply/3`, captured
  functions, behaviour callbacks, `state.http_fn`), except where manual source
  context connected the call as it did for the HTTP rows;
- calls generated only after macro expansion, because the instrument walks
  parsed source AST rather than expanded quoted code;
- timeouts internal to NIFs, ports, OS commands, database engines, or dependency
  applications; the project-side call can be marked unbounded, but the hidden
  implementation cannot be enumerated from `apps/*/lib`;
- pool checkout mechanisms other than the inspected Req/Finch path, including
  future poolboy/NimblePool consumers reached by dynamic configuration;
- cross-app or remote-node code not present in this worktree, including a serve
  running a stale/different beam;
- runtime-computed values whose expression is visible but whose deployed value
  depends on app env, interface documents, or state; these are rows marked
  `dynamic`, not guessed numbers;
- handler nesting behind a `GenServer.call` when the handler reaches a budget
  through an injected module or data-dependent branch. Such rows say
  callback-dependent; only evidenced chains above are asserted as closed facts.

Consequently “272 rows” is a scoped source census, not a claim that production
can execute only 272 waits.

## Regression check and deviations

Dependencies were not writable/present in this isolated worktree. Per the
sandbox preamble, `/home/jes/commonplace/deps` was copied to
`/tmp/cx11ms-deps`, with `MIX_DEPS_PATH=/tmp/cx11ms-deps` and
`MIX_BUILD_PATH=/tmp/cx11ms-build` used for compilation/tests.

The first ordinary umbrella-start attempt did not enter ExUnit: the configured
test web port was already owned (`:eaddrinuse`). A second wrapper attempt used
the wrong Mix environment and stopped before ExUnit on a missing test-only app.
Neither is reported as a test failure or negative result. The counted
regression run used `MIX_ENV=test`, started only `:commonplace`, and invoked the
same `apps/commonplace/test` scope through Mix test `--no-start`; its final
count is recorded in the run report below.

The umbrella root defines no `precommit` alias. The similarly named web-app
alias was not substituted: it includes a repository formatter, which conflicts
with this round's explicit no-repo-wide-formatting and zero-production-change
constraints. This is reported as a project-guideline deviation rather than
silently broadening the gate.

The normal distributed tix route could not read the cookie because the sandbox
presents `/home/jes/.erlang.cookie` as a character device. No absence was
claimed from that failure. The sanctioned process-derived store path was copied
to `/tmp` and read there; CX-11ms was the positive control, followed by the
salvage ticket. No new ticket was filed: the census observations belong to
CX-11ms and the mapped salvage defect already has an operator ticket.

No production file, test file, configuration, or `sol-run.log` was changed.
All repository work remains uncommitted as required.

## Run report

**CX-11ms result:** valid, non-void DISC census; builds none of the destination
frame. Scope was 429 production source files. The call-site AST instrument
emitted 300 nodes; source classification retained 272 production seam rows and
separately accounted for 36 cadence/debounce/drain exclusions. It enumerated
call nodes rather than timeout literals, so bare calls carrying invisible
defaults are present.

**Controls:** all three known members were found, including both invisible
5,000ms defaults and the test-only explicit 30,000ms member. The seeded
`GenServer.call/3` raised the instrument from 300 to 301 records, was emitted at
its exact file:line, was removed, and the sweep returned byte-for-byte to the
300-record baseline. The named structural blind spots are recorded above; the
272-row count is not presented as a closed runtime call graph.

**Regression:** baseline for this worktree and scope was 3,400 tests, zero
failures, one skipped. The first counted full-core run finished with 5 doctests,
3,400 tests, one failure, 12 excluded, and one skipped. Its recorded failed-test
replay then passed one test with zero failures. Because the original noisy PTY
stream did not retain the failure header, the same full scope was rerun with
the original seed and stop-on-first-failure to make either error shape or
success falsifiable. That final run finished in 660.4s with 5 doctests, 3,400
tests, zero failures, 12 excluded, and one skipped, matching the baseline.

**Stops and deviations:** two setup attempts stopped before ExUnit with the
specific `:eaddrinuse` and missing-test-app shapes and were not counted. The
distributed tix read stopped on the sandbox cookie's character-device shape;
the sanctioned store snapshot supplied positive reads instead, and no new
ticket was needed. Copied dependencies and isolated build paths were required.
The absent umbrella `precommit` alias was not replaced by the web-app alias
that would repo-format. No production/test/configuration file or operator log
was changed. The sole repository artifact is this uncommitted census note.
