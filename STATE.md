# Project state

## FRONTIER

> RENDERED 2026-08-07T01:27Z — TRUST UNTIL 2026-08-07T02:12Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

Ready: **243** · Blocked: **12**
- `CX-4k36` [p1] chat-over-web bots: audit serve wiring + make real on the web chat surface — claimed_by: unclaimed
- `CX-9rd3` [p1] Unified permission model — read + code perms on the cert backbone — claimed_by: unclaimed
- `CX-a449` [p1] Flock NIF cannot load inside the CLI escript — embedded app boot dies at CommitStore.init (found by CX-x8jk live smoke) — claimed_by: unclaimed
- `CX-bxsh` [p1] chat-over-mcp bots: audit + make real on the MCP chat surface (loom_send/loom_read) — claimed_by: unclaimed
- `CX-dzfv` [p1] tix-migration step 3: cutover — all agents switch to tix verbs, bd sync daemon retired — claimed_by: unclaimed
- `CX-ght7` [p1] Chat-bots: genuine signed principals across all surfaces (web + mcp + worker) — claimed_by: unclaimed
- `CX-mchn` [p1] Yelixer: full-state-snapshot-into-chained-commit delete_set OVER-COVERS a fresh insert on apply_update re-fold (silent data loss) — claimed_by: unclaimed
- `CX-t3bt` [p1] Probe-side read staleness: reconstruct-read of a recently-appended entries-doc served pre-append state ~50min later — forensics nearly misread live state — claimed_by: unclaimed
- `CX-tdkq` [p1] Architecture-review follow-ups — claimed_by: unclaimed
- `CX-x8jk` [p1] CLI escript opens the live store via cwd data-dir resolution — documented usage is a corruption hazard — claimed_by: unclaimed
- `CX-0ii3` [p2] @verb editor pre-fill/preview showed EMPTY for existing SAFE verbs (read_source looked up legacy .elx only) — claimed_by: unclaimed
- `CX-15ff` [p2] PullClient periodic-poll: re-offered back-filled genesis :already_exists crashed poll GenServer — claimed_by: unclaimed
- `CX-1azj` [p2] Code-signing-key separation — data-key compromise != RCE (gates broad self-hosting) — claimed_by: unclaimed
- `CX-1f64` [p2] CLI escript has no freshness check — stale binary is a second authoring surface (check-mcp-fresh covers MCP only) — claimed_by: unclaimed
- `CX-1uf1` [p2] Capability-GRANT verb — in-game delegation of edit powers — claimed_by: unclaimed

## IN-FLIGHT

> RENDERED 2026-08-07T01:27Z — TRUST UNTIL 2026-08-07T02:12Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- `CX-4u03` Zone-ownership M2: growing zones — Tree.ChildMutation chokepoint + move-cleared zone-stamp — status: in_progress · holder: unclaimed
- `CX-aya0` MUD-as-docs Inc-2: stateless-leaf verbs (look/examine/inventory/emote/say) doc-hosted via SourceDoc.compile + Gate-B — status: in_progress · holder: unclaimed
- `CX-cj3t` (EPIC) MUD improvement — fix + harden the multiplayer MUD from dogfood findings — status: in_progress · holder: unclaimed
- `CX-fogy` Verb-authoring M1: execute-safe cert at home-genesis + editable-flag gate fix (trust-core) — status: in_progress · holder: unclaimed
- `CX-2o9o` Safe-verb gate: compile errors are surfaced opaquely ('errors have been logged') — hide the real diagnostic + line — status: in_progress · holder: unclaimed
- `CX-3hv0` Ticket-DAG S5: migrate ~214 open beads → live ticket-DAG (import + three-way verify + cutover) — status: in_progress · holder: unclaimed
- `CX-73a3` Read-scoping P3: read-enforce parity + the COMPLETENESS AUDIT (no-bypass) — status: in_progress · holder: unclaimed
- `CX-aw4r` Safe verbs have no actor-attribution: Facade.emit renders identical text to actor and observers — status: in_progress · holder: unclaimed
- `CX-cgs` Wiki-style web UI demo — status: in_progress · holder: unclaimed
- `CX-cj3t.9` Facade.move budget/semantics — owner_grant_exceeded makes it unusable for gameplay — status: in_progress · holder: unclaimed
- `CX-hh70` MUD onboarding: 'examine' on puzzle objects appends raw State block that SPOILS the answer — altar shows 'expect: spark' + 'solved: yes' — status: in_progress · holder: unclaimed
- `CX-hqk5` Safe verbs are stateless + read-only: no way to build stateful mechanics (persistent flags, lit/unlit, score, gated puzzles) — status: in_progress · holder: unclaimed
- `CX-mxxe` MUD: examine dumps full verb state to any player — puzzle spoilers + actor_ref→name mapping leak — status: in_progress · holder: unclaimed
- `CX-nyj9` Mint-with-behavior / spawn-from-template — configure a freshly-minted object (TRUST-SENSITIVE) — status: in_progress · holder: unclaimed
- `CX-q9aj` Smoke-test commonplace MCP tools per boss-clod ask — status: in_progress · holder: unclaimed
- `CX-qat5.7` MUD M1: server exposure — bind-beyond-localhost / tailscale / TLS (HUMAN-GATED, exposure) — status: in_progress · holder: unclaimed
- `CX-rmk` Layer 2 MCP server for commonplace channels — status: in_progress · holder: unclaimed
- `CX-uwam` Key-gated container: take-from bypasses custom key-check (the 'lock is theater' gap) — status: in_progress · holder: unclaimed
- `CX-vfau` CX-60na Green half: bursar adoption wave + author-facing acquire/release verbs + cluster-arbiter design residual + docs — status: in_progress · holder: unclaimed
- `CX-vt9l` Relational + search as commonplace profiles (F3, derivation records, one index instance) — status: in_progress · holder: unclaimed
- `CX-wkau` Self-host: ~20 gameplay verbs (take/drop/give/put/mine/smith/get/examine/search/…) are compiled-in dispatch_builtin, not doc-hosted engine modules → continue the Inc-1 pattern — status: in_progress · holder: unclaimed
- `CX-xe0r` MUD: 'look <player>' cannot target other LIVE players — room lists them in Players:, self-look works, give resolves them — status: in_progress · holder: unclaimed
- `CX-ypgf` MUD parser: preposition swallowed as noun + substring match across words — 'step on warppad' → "You can't step iron ingot" — status: in_progress · holder: unclaimed
- `CX-z6ub` Verb-authoring M2: standard verb set as node-signed prototype (inherited, override-on-top) — status: in_progress · holder: unclaimed
- `CX-0t2r` Reflog checkpointing silently dormant on the live serve since 2026-04-25; would be trust-denied if it ever fired — status: in_progress · holder: unclaimed
- `CX-cj3t.10` Directed / self-only messaging Facade primitive (whisper / tell-actor / per-player outcome) — status: in_progress · holder: unclaimed
- `CX-hbbi` Container spoiler: 'look <container>' reveals contents of a locked/shut container — status: in_progress · holder: unclaimed
- `CX-oj83` MUD NPE: newcomer critical path dead — Warded Vault brass KEY looted, no respawn; room copy still advertises it — status: in_progress · holder: unclaimed
- `CX-u7kj` MUD web console: excess vertical whitespace between command output blocks — status: in_progress · holder: unclaimed

## RECENT CLOSES

> RENDERED 2026-08-07T01:27Z — TRUST UNTIL 2026-08-07T02:12Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- `CX-g486` 2026-08-07T01:09:05.810292Z — AuditChokePerfTest deny arm: measure the OFFERED-denial path (under-cap), not only storm suppression — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-oc30` 2026-08-07T00:43:38.838403Z — Trust audit log has recorded NOTHING on the live serve — RedLog.commit writes unsigned, so every audit write is denied by the gate it exists to audit — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-pm68` 2026-08-07T00:43:35.979872Z — CommitStore corrupt-open policy silently substitutes an EMPTY world ("Archiving and starting fresh") — enforce serves must refuse to boot — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-2479` 2026-08-07T00:43:33.578936Z — commits.lock excludes nobody — second opener overwrites the pid instead of being refused — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-xmsd` 2026-08-06T18:45:43.497947Z — Comment writes never pass WriteGuard — the single-gated-write-path property is true of tickets, not comments (found building CX-6n62 tooling) — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-t3xv` 2026-08-06T11:11:21.699755Z — P1: the FIRST enforce-mode denial on a node permanently kills denial auditing — audit persist GenServer.calls back into the CommitStore mid-handle_call, exits :calling_self, telemetry detaches the trust-audit-log handler for the VM lifetime — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-ggdv` 2026-08-06T10:08:45.506093Z — Walk-bounding: pin reads walk backward FROM THE TARGET to the nearest snapshot — kill the full-history-linear commit_log term (M3 finding; byte-neutral by fence) — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-6scm` 2026-08-06T07:29:17.844784Z — P1: chain replay (reconstruct_doc_at / reconstruct_doc) silently drops entries on full-state-rewrite chains — 80/2376 dir_schema docs disagree with the live read path AT HEAD, 124 tree entries lost — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-hrbn` 2026-08-06T04:33:39.501984Z — Cutover scope (CX-dzfv gate): Bd.Ready reads deps.json, which freezes at cutover — retire it with bd, repoint it at needs, or make it refuse loudly — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-mmxr` 2026-08-05T21:52:52.544718Z — tix-migration: the 521 closed bd tickets — migrate as batch vs archive-in-bd (jes's scope call) — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-1duj` 2026-08-05T21:50:03.510366Z — Ticket-DAG: thin CLI/UI for the on-substrate dev-DAG (day-1 is MCP verbs + Frontier RPC) — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-ajdx` 2026-08-05T21:50:01.851225Z — Wiki fork button (ViewActionDispatch fork + CommandRouter.fork) writes unsigned genesis commits → latently BROKEN on the live enforce serve — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-f3ob` 2026-08-05T21:50:00.520236Z — Ticket-DAG (Bd P2): graph-vocabulary lift of on-substrate beads — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-o9kj` 2026-08-05T21:49:58.928880Z — Dogfood deploy gap: MCP escript not rebuilt on deploy — relaunch verified stale pre-fix code — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-n3i7` 2026-08-05T21:49:57.787875Z — [security] Yelixer XMLElement.to_string/2 does not HTML-escape text or attributes — XSS if raw-rendered on web — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-fml6` 2026-08-05T21:49:56.638551Z — MUD escript serve-discovery pins to STALE ORPHAN serve node; orphan serve nodes accumulate (temp-node hazard) → recurring stale-code crashes — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-p6g0` 2026-08-05T21:49:55.481609Z — Bursar went DOWN on the :5199 serve under enforce (deploy #4, 708e00c) — root unreproduced; take/move crashed on :bursar_unavailable — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-zy4q` 2026-08-05T21:49:54.306095Z — P1: Start Room (public hub 9d6b7039) flipped private/unreadable MID-SESSION — all citizens incl. fresh spawns locked out of entire demesne — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-6n62` 2026-08-05T21:15:15.894397Z — tix-migration step 2: migrate the 26 live bd-only tickets, ids preserved, through the gated import — 3-way acceptance + scanner reads zero — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-xxav` 2026-08-05T20:58:21.036406Z — P1: merge_completed advertises a commit id that is stored NOWHERE — 76dcd3c (snapshotter_version 1->2) broke the path that used to store it, and persist_commit's swallowed :parent_moved hid the divergence — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-jfok` 2026-08-05T20:22:29Z — Invariant registry step 2: bind the engine to the head-advance choke (put_latest funnel + async alarm dispatch) — §4.2, R1/R2/R9 — **WHAT-THE-FIX-WAS:** Shipped @a49dcc5 (5 commits on 170b66f).
- `CX-6cz3` 2026-08-05T20:02:26.285372Z — tix-migration step 1: gated ticket_import + ticket_create verbs (WriteGuard chokepoint for supplied-id and minted-id creation) — **WHAT-THE-FIX-WAS:** **(no close evidence recorded)**
- `CX-9fyz` 2026-08-05T17:45:49Z — Invariant registry + engine: declare the four base checks as invariant objects (resting-state design §4.1/4.2 step 1) — **WHAT-THE-FIX-WAS:** Shipped @f7ac5bd.
- `CX-mg8s` 2026-08-05T14:44:37Z — all_commit_ids_for_doc silently skips every commit whose id starts with byte 0xFF (~1/256) — CubDB range bound is wrong — **WHAT-THE-FIX-WAS:** Fixed @13d03d6.
- `CX-vknn` 2026-08-05T12:46:44Z — VersionHandshake's MCP session-start skew warning still samples 6 fixed probe modules (pair to CX-o1b9) — **WHAT-THE-FIX-WAS:** Fixed @4249503.
- `CX-g8s9` 2026-08-05T12:14:47Z — write_meta_doc's verify-then-commit window is its own race — blocks closing the 8-way CAS gap — **WHAT-THE-FIX-WAS:** Fixed and deployed @b87b21a (deploy #32, serve 179372).
- `CX-r97r` 2026-08-05T11:59:20Z — Concurrent NoteDoc appends CORRUPT the doc into unparseable JSON, all writers get :ok, and read_entries masks it as an empty list — **WHAT-THE-FIX-WAS:** Main body fixed and pushed @23eb561.
- `CX-hqko` 2026-08-05T07:34:35Z — A :regular commit whose parent is legacy-%{} gets NO snapshot_parent and is then unconditionally rejected on import — blocks any legacy→modern metadata migration — **WHAT-THE-FIX-WAS:** FIXED, SHIPPED, AND LIVE.
- `CX-x073` 2026-08-05T07:33:31Z — Scheduler.Agent is fully built but nothing ever starts it — schedule requests silently get no reply on any standard boot — **WHAT-THE-FIX-WAS:** Shipped @0515696, live since deploy #29/#30.
- `CX-gvbf` 2026-08-05T06:39:58Z — Freeze pin: write terminal-state pin at close + closed-matches-pin invariant (CX-o3ar durable fix) — **WHAT-THE-FIX-WAS:** SHIPPED AND LIVE — main @757a023, deploy #30 (beam 34846 → 47347), 2026-08-05.
- `CX-o1b9` 2026-08-05T06:34:17Z — bin/check-mcp-fresh reports FRESH in complete language but only samples 6 fixed probe modules — **WHAT-THE-FIX-WAS:** Fixed @62b0f66.
- `CX-inlb` 2026-08-05T04:16:50Z — Audit the 55 content docs that reconstruct EMPTY on the live serve — **WHAT-THE-FIX-WAS:** Audited.
- `CX-2xn1` 2026-08-05T00:45:29Z — Yelixer: Doc.snapshot_update/1 silently DESTROYS one whole kind on a mixed keyed+plain sequence — **WHAT-THE-FIX-WAS:** Fixed @9fae400 on main.
- `CX-vt9l.5` 2026-08-04T23:48:26Z — Black.json/2 silent-empty: directory docs, content-less docs, and genuinely empty rows are indistinguishable ({:ok, %{}}) — **WHAT-THE-FIX-WAS:** FIXED @089093d.
- `CX-vt9l.6` 2026-08-04T21:39:17Z — Black.select/Query silently truncate on TWO axes (limit + max_depth) with no signal in the return — blocking for any SELECT surface — **WHAT-THE-FIX-WAS:** Scan truncation now reported on BOTH axes.
- `CX-vt9l.2` 2026-08-04T21:39:16Z — Slice 2: derivation-record convention (named shape + adoption) — **WHAT-THE-FIX-WAS:** Derivation-record convention + adoption.
- `CX-vt9l.1` 2026-08-04T21:39:15Z — Slice 1: F3 ephemeral query docs + query-result-as-witness-doc — **WHAT-THE-FIX-WAS:** F3 pinned queries + result-witness docs.
- `CX-ud1u` 2026-08-03T05:52:40Z — Split MUD verbs.ex (2890 lines): extract Resolver + Rendering at the existing section seams — **WHAT-THE-FIX-WAS:** Both halves of the god-module split done.
- `CX-vzod` 2026-08-03T05:42:39Z — DocBuilder.reconstruct_doc silently reconstructs from a mid-chain start when a parent commit is missing — **WHAT-THE-FIX-WAS:** Loudness fix: reconstruct_doc now emits Logger.warning + chain_incomplete telemetry when the fetched chain neither grounds at genesis/nil-parent/snapshot nor fills the cap page (short page + dangling parent_id = store genuinely missing a commit).
- `CX-2t8p` 2026-08-03T05:39:29Z — BotPresenceCertTest re-spawn flake under load: send_input hits dead bot session after CX-vj8v registry+lease respawn — **WHAT-THE-FIX-WAS:** Confirmed real production race (not test-harness-only): Registry unregisters a {:via, Registry, ...}-named PlayerSession by processing the dying process's :DOWN in the REGISTRY's own process, asynchronously relative to Bot.stop/1's (GenServer.stop/2) synchronous return on the caller side.
- `CX-wrg0` 2026-08-03T05:39:03Z — InodeTracker second growth vector: shadowed-but-never-diverged entries never reach reconciliation cleanup — **WHAT-THE-FIX-WAS:** Fixed: added generation-supersession cleanup.
- `CX-klpi` 2026-08-03T02:41:05Z — CommitStore commit_log 10k cap silently truncates to newest window — trust gates authorize against partial history — **WHAT-THE-FIX-WAS:** Both halves complete.
- `CX-izol` 2026-08-03T01:59:51Z — General architecture study of commonplace (Fable, 2026-08-03) — file beads for gaps — **WHAT-THE-FIX-WAS:** Architecture study complete + execution phase largely done same-day.
- `CX-xrds` 2026-08-03T01:56:28Z — CommitStore corruption recovery: 1-row integrity probe + whole-store lossy rename granularity — **WHAT-THE-FIX-WAS:** Deepened probe_integrity/1 to a time-bounded full scan (default 5s, configurable via Application.get_env(:commonplace, :corruption_probe_timeout_ms)); timeout treated as healthy (availability over paranoia), raise treated as corrupt.
- `CX-hilo` 2026-08-03T01:48:48Z — No persisted trust-decision audit trail — denials and revocation hits are telemetry-only, audit/ is a false-friend name — **WHAT-THE-FIX-WAS:** Implemented Commonplace.Trust.AuditLog: telemetry handler bridging the three trust-rejection events into RedLog, attached at app boot, flood-guarded (cap 20/min/event, summary on rollover).
- `CX-42no` 2026-08-03T01:48:22Z — Watcher/Sync.Agent disk reads raise uncontained — one bad file (perms/symlink cycle) crash-loops a checkout forever — **WHAT-THE-FIX-WAS:** Implemented @4cb00fe: rescue-and-skip on all per-file disk reads in Watcher (apply_create/apply_modify/modified-detector/match_by_content) and Sync.Agent (outbound modified-filter read_locked/1, check_shadows), each logging once via Logger.warning with the posix reason and skipping the entry.
- `CX-fg1e` 2026-08-03T01:47:12Z — Direct test coverage for holder_move.ex and sections.ex (zone/ownership logic, security-adjacent) — **WHAT-THE-FIX-WAS:** Added apps/commonplace/test/commonplace/mud/holder_move_test.exs (7 tests) and sections_test.exs (8 tests), direct coverage of HolderMove.push and Sections.
- `CX-oh9z` 2026-08-03T01:41:13Z — Yelixer snapshot_update/1 should refuse lossy compaction itself instead of relying on every caller to pre-check — **WHAT-THE-FIX-WAS:** snapshot_update/2 refuses lossy nested-subtype compaction by default, force: true opt-in preserves old behavior.
- `CX-pb23` 2026-08-03T01:41:12Z — Add Yelixer.Doc.state_vector/1 — a dozen commonplace call sites reach through doc.store to BlockStore — **WHAT-THE-FIX-WAS:** Doc.state_vector/1 added (apps/yelixer/lib/yelixer/doc.ex), 12 .store reach-through sites converted across apps/commonplace (compactor, translator, session_view x6, cherrypick, merge x3, git_bridge/inbound x2).
- `CX-6bqk` 2026-08-03T01:39:21Z — CAS write path: fixed 5-attempt constant, no telemetry when optimistic writes exhaust and fall back to serialized path — **WHAT-THE-FIX-WAS:** Added Application.get_env(:commonplace, :commit_cas_max_attempts, 5) (default unchanged) and :telemetry.execute([:commonplace,:commit,:cas_exhausted], %{attempts: n}, %{uuid: doc_uuid}) + Logger.debug at the single fallback transition in attempt_write/10's base clause (commit_store_client.ex).
- `CX-k34x` 2026-08-03T01:39:20Z — InodeTracker.Registry grows without bound — tracked shadow entries never evicted — **WHAT-THE-FIX-WAS:** Fixed: check_shadows/1 (agent.ex) now evicts the Registry entry after a reconciled shadow's content is folded into the CRDT and the shadow file is removed.
- `CX-6cgl` 2026-08-03T01:33:41Z — Repo hygiene: gitignore priv/*.so, remove stale erl_crash.dump, rename misleading CommitStore alias in inspect_cmd — **WHAT-THE-FIX-WAS:** Gitignored apps/commonplace/priv/*.so, removed stale erl_crash.dump, renamed CommitStoreClient alias in inspect_cmd.ex (one true call site; two other fully-qualified CommitStore.latest_commit/2 calls are a distinct store-struct API and were left alone).
- `CX-usv6` 2026-08-03T01:33:41Z — CLAUDE.md architecture section is stale: says four apps (there are six), calls commonplace_web early stage — **WHAT-THE-FIX-WAS:** Updated CLAUDE.md: six apps listed (added commonplace_mcp, commonplace_bots), commonplace_web description corrected, MUD + trust/enforce-mode bullets added.
- `CX-vj8v` 2026-08-03T01:30:43Z — MUD.Bot still uses :global registration — the retired MoveServer/TickBot netsplit/name-conflict hazard, unfixed for 1 of 3 siblings — **WHAT-THE-FIX-WAS:** Code-side fix @288fb1d: MUD.Bot now registers locally via {:via, Registry, {Commonplace.MUD.BotRegistry, name}} (new :unique Registry child in Application) instead of {:global, {Bot, name}}.
- `CX-x9vj` 2026-08-03T01:27:24Z — Targeted test: can re-importing an old still-valid snapshot commit regress field values via CRDT clock semantics? — **WHAT-THE-FIX-WAS:** Investigated: re-importing an old snapshot commit (import_commit content-address dedup, no-op) and re-chaining its raw update bytes as a new commit (idempotent per-(client,clock) apply_update, no-op even against a disjoint-client-id post-snapshot writer) do NOT regress LWW field values, before or after a newer snapshot is cut.
- `CX-l5js` 2026-08-03T01:25:15Z — Presence set_activity/set_attributes never thread signing — silently dead the day a workspace goes strict — **WHAT-THE-FIX-WAS:** Threaded opts/signing through Presence.set_activity/3 and set_attributes/3 (now arity-4, opts \\ []), matching update_status/4 exactly (SignedWrite.opts_for/2).
- `CX-inpn` 2026-08-03T01:21:54Z — Nested-subtype docs permanently refuse snapshots with no operator surface — unbounded chains feeding the 10k-cap truncation — **WHAT-THE-FIX-WAS:** Fixed: SnapshotSweeper GenServer now accumulates {doc_uuid, names} for every {:ok, :skipped, {:nested_subtypes,...}} result per sweep tick into state, replacing the previous set wholesale (stuck-fixed docs drop off naturally), exposed via stuck_docs/1.
- `CX-d029` 2026-08-03T01:20:29Z — GitBridge crash containment: Inbound.run unrescued; one crash-looping mount can reset every mounts in-memory state — **WHAT-THE-FIX-WAS:** Code fix landed @f6a9ade: (a) Server.run_cycle now wrapped in run_cycle_guarded/1 (rescue+catch backstop), logs Logger.error+telemetry [:commonplace,:git_bridge,:tick_crashed]+red PubSub, returns PRIOR state (tick skipped) instead of crashing the GenServer; (b) Inbound.ingest_text's Base.decode16!
- `CX-dvtj` 2026-08-03T01:14:11Z — Sync EntryAgent lacks the CX-60wl inbound-clobber guard; accepts shadow_dir but never uses it — **WHAT-THE-FIX-WAS:** Ported CX-60wl inbound-clobber guard into EntryAgent.sync_inbound @cf20fff; shadow_dir plumbing deferred to CX-bpx9
- `CX-vyrs` 2026-08-03T01:11:57Z — Effective-enforcement-posture introspection: three trust knobs must agree, no single place reports them — **WHAT-THE-FIX-WAS:** Added Commonplace.Trust.posture/0 (resolved accept_unsigned/trusted_identities_count/local_write_gate/local_read_gate/strict) + boot-time Logger.info in Commonplace.Application.start/2 + updated trust.ex moduledoc gate topology paragraph.
- `CX-a7i2` 2026-08-03T01:11:56Z — local_read_gate has no production activation path — read enforcement for the P3 cohort cannot be turned on — **WHAT-THE-FIX-WAS:** Added COMMONPLACE_LOCAL_READ_GATE env-var bridge in config/runtime.exs, mirroring the CX-qat5.7 write-gate bridge (permissive default unchanged).
- `CX-tu7a` 2026-08-03T01:11:06Z — git_bridges.json written non-atomically; decode failure silently drops ALL git mirrors on boot — **WHAT-THE-FIX-WAS:** Fixed: write_mappings now atomic (temp file + rename, same idiom as CheckoutRegistry.atomic_write/2); read_mappings on JSON decode failure now logs loudly, archives the corrupt file to git_bridges.json.corrupt.<unix-ts>, then returns [].

## OPEN-WITH-BLOCKER

> RENDERED 2026-08-07T01:27Z — TRUST UNTIL 2026-08-07T02:12Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

- `CX-5le4` Bd.Frontier.Server never started in production — ready/blocked view-docs and dependency-hell alarm never fire on the serve — RIDER DONE @10a3156 (prophylactic only — the bead itself is untouched and still blocked on poll-vs-push).
- `CX-nyvm` Mode A vs Mode B serve boot-gate parity (bursar_on_boot found missing; audit other on-boot gates) — THIRD INSTANCE OF THIS PARITY TRAP (2026-08-05, from CX-fml6).
- `CX-x8jk` CLI escript opens the live store via cwd data-dir resolution — documented usage is a corruption hazard — Code-complete @5d49396 (prose-lock deleted — kill -0 measures signal PERMISSION not liveness; decision table route/refuse/local; probe proven non-evicting; data-dir provenance line).

## TRACKER-TRUST

> RENDERED 2026-08-07T01:27Z — TRUST UNTIL 2026-08-07T02:12Z. Reading this later?
> IT IS STALE: do not scope from it. Fallback: bin/state-render, or
> tix via serve erpc, or git log --oneline --since=<week>.

scanner has not run
