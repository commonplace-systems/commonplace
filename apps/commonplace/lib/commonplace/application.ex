defmodule Commonplace.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # CX-qvrz: this runs synchronously in the application callback, before
    # Commonplace.Supervisor (and therefore every store/MUD caller of
    # NodeIdentity.public_key/0) exists. The migration reads only the legacy
    # key file's public first line and never mints an identity.
    :ok = Commonplace.Crypto.NodeIdentity.publish_public_keys_at_boot()

    # :xmerl is used by Commonplace.Document.ViewXml for parsing view XML
    # documents. Ensure it's loaded at app start so `mix phx.server` and
    # other dev-mode entry points don't require a cold restart after the
    # dep is first added.
    _ = Application.ensure_all_started(:xmerl)

    # CX-fogy (c) — composition-root injection of the MUD safe-verb allowlist
    # PROFILE (the facade action-set + wrapper shape, as DATA) into the app env.
    # `Commonplace.Trust`'s write-fork classifier reads this to run the CORE,
    # domain-agnostic `Commonplace.Code.Allowlist` — so Trust never references the
    # MUD domain, and the RCE-ban wall stays core-owned. Fail-closed: if this is
    # unset, the classifier can't recognize a sandboxed safe-verb and every code
    # write falls to `:execute` (node-only). Set here (the composition root, which
    # is allowed to know both layers) so it's live before any write is gated.
    Application.put_env(
      :commonplace,
      :safe_verb_profile,
      Commonplace.MUD.SafeVerb.Allowlist.profile()
    )

    # CX-o8tx: feed reflog amortization's dirty-set from local commit
    # creates. Idempotent attach — re-attach on app restart is harmless
    # because telemetry treats handler_id as a primary key.
    _ = :telemetry.detach("commonplace-reflog-dirty-tracker")

    :ok =
      :telemetry.attach(
        "commonplace-reflog-dirty-tracker",
        [:commonplace, :commit, :create],
        &Commonplace.Reflog.Snapshot.handle_commit_event/4,
        nil
      )

    # CX-m0qw: create the per-BEAM-boot denominator before a denial can
    # reach the audit telemetry handler. This is an atomic primitive, not a
    # supervised process; the denial decision site increments it directly.
    :ok = Commonplace.Trust.DenialCounter.init()

    # CX-hilo / CX-t3xv: durable trust-decision audit trail. Bridges the
    # denial telemetry events enumerated in `Commonplace.Trust.DenySites`
    # into a red-log doc, so a security-incident review has a data source
    # beyond "who was tailing the live log at the time." Idempotent
    # attach, same detach/attach idiom as the reflog dirty-tracker above.
    #
    # The handler only builds a record and casts it to
    # `Commonplace.Trust.AuditDispatcher` (started below). It deliberately
    # does NO store work: telemetry handlers run in the process that fired
    # the event, and the loudest denial event fires from inside
    # CommitStore's `handle_call`, where any call back into the store is
    # `:calling_self` — an EXIT, which `:telemetry` answers by permanently
    # detaching the handler. See `Commonplace.Trust.AuditLog` for the full
    # etiology, the flood guard, and the recursion guard.
    _ = Commonplace.Trust.AuditLog.attach()

    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    children =
      [
        {Registry, keys: :unique, name: Commonplace.Document.Registry},
        {Registry, keys: :unique, name: Commonplace.SchemaCoordinator.Registry},
        {Phoenix.PubSub, name: Commonplace.PubSub},
        {Cluster.Supervisor,
         [Commonplace.Cluster.topology(), [name: Commonplace.ClusterSupervisor]]},
        Commonplace.Cluster.EventHandler,
        # R4c carve-out: CommitStore's capability store, execute_clean
        # watermark cache, and R11 pending-imports retry queue were
        # extracted into their own processes (TrustSideStore,
        # PendingImports). `Commonplace.Store.Supervisor` supervises the
        # trio with `:rest_for_one` (see its moduledoc for why). Nested
        # here under the same `id` the old bare-CommitStore wrapper used,
        # so the outer `Commonplace.Supervisor`'s restart accounting for
        # "the store subsystem" is unchanged; that outer supervisor is
        # `:one_for_one` so a fatal, repeated failure of the whole store
        # subsystem doesn't cascade into restarting unrelated siblings.
        %{
          id: Commonplace.Store.CommitStoreSupervisor,
          type: :supervisor,
          start:
            {Commonplace.Store.Supervisor, :start_link,
             [[data_dir: data_dir, name: Commonplace.Store.CommitStoreSupervisor]]}
        },
        # CX-jfok: the alarm half of the resting-state invariant layer.
        # Started right after the store subsystem because that is what
        # feeds it — `CommitStore.put_latest/5` casts every head advance
        # here. Unconditional and cheap: it is idle until an advance
        # arrives, and `:invariant_dispatch_enabled` (false in
        # config/test.exs) makes even that a counter bump. The task
        # supervisor is where validation actually runs, so a recompute
        # never occupies either the store's mailbox or the dispatcher's.
        {Task.Supervisor, name: Commonplace.Invariants.TaskSupervisor},
        Commonplace.Invariants.Dispatcher,
        # CX-t3xv: denial auditing, out of the store's execution context.
        #
        # Started right after the store subsystem for the same reason the
        # invariant dispatcher is: the store is what feeds it. The
        # telemetry handler attached above casts denial records HERE, and
        # the persist runs in the task supervisor — never in
        # CommitStore's mailbox, which is what `:calling_self`-killed the
        # previous build.
        #
        # Acceptance criterion 7 ("is it started" closed structurally) is
        # these three lines plus the canary: the auditor's starter is in
        # the supervision tree of the deployed serve, and the canary is
        # the continuous witness that it is doing its job.
        {Task.Supervisor, name: Commonplace.Trust.AuditTaskSupervisor},
        Commonplace.Trust.AuditDispatcher,
        Commonplace.Trust.AuditCanary,
        {Commonplace.Store.SecretStore, data_dir: data_dir},
        Commonplace.Tree.DocCache,
        {DynamicSupervisor, name: Commonplace.SchemaCoordinator.Supervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: Commonplace.Document.Supervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: Commonplace.Checkout.Supervisor, strategy: :one_for_one},
        {Commonplace.Dataflow.GraphRegistry, []},
        Commonplace.CommandRouter,
        # R4(b) / CX-tdkq.4: single-flight scheduler in front of
        # SnapshotTrigger for the reader-side lazy-snapshot path (replaces
        # the per-doc ETS debounce). Idle until DocBuilder requests a snapshot.
        Commonplace.SnapshotWorker,
        Commonplace.Chat.OnrampSupervisor,
        Commonplace.Chat.ChatViewComputeSupervisor,
        # CX-o1l9 (Black M1): pattern-scoped compute supervisor —
        # substrate-tier sibling of ChatViewComputeSupervisor above,
        # domain-agnostic (caller-supplied key, not a chat room name).
        Commonplace.Black.PatternComputeSupervisor,
        # MoveServer is RETIRED (move #4, CX-tdkq.7): cross-doc moves now
        # take per-path green tokens (Commonplace.MUD.Move) instead of
        # serializing through a :global singleton. TickBot remains an
        # unconditional child but only ticks while holding the green tick
        # lease — on nodes with no Bursar route it idles, fail-closed.
        Commonplace.MUD.TickBot,
        # CX-i9j3 (UI Inc-1 increment 4): identity_uuid -> SessionView
        # view_uuid pointer, so a browser reconnect can `SessionView.load/2`
        # its prior transcript instead of minting a fresh one. In-memory
        # only (see its moduledoc) — no deps beyond being a plain Agent, so
        # it's safe to start unconditionally on every boot (dev/prod/test).
        Commonplace.MUD.SessionViewRegistry,
        # CX-3xwu: filename-keyed presence registry — a PlayerSession
        # registers its `.usr` presence_filename here on init and is
        # auto-unregistered on process death (crash or clean-quit alike).
        # `who` filters the tree-walk's `.usr` collection by membership
        # here so stale presence ghosts (dead session, tree entry still
        # present) don't render. Keys on live-session existence, NOT
        # heartbeat recency. :duplicate because multiple pids may
        # transiently share a key during handoff; any registration = live.
        # Safe to start unconditionally alongside SessionViewRegistry above.
        {Registry, keys: :duplicate, name: Commonplace.MUD.PresenceRegistry},
        # CX-vj8v: local :unique registry for `Commonplace.MUD.Bot`
        # PlayerSessions — replaces the retired `{:global, {Bot, name}}`
        # registration (the same netsplit/name-conflict hazard
        # MoveServer/TickBot already retired: `:global` name-conflict
        # resolution on node join can kill or orphan a bot session, and a
        # netsplit lets two exist at once). `:unique` because there is at
        # most one live session per bot name PER NODE; cluster-wide
        # exclusivity across nodes is a green-token lease taken by `Bot`
        # itself (see its moduledoc), not `:global`. Safe to start
        # unconditionally alongside PresenceRegistry above.
        {Registry, keys: :unique, name: Commonplace.MUD.BotRegistry},
        # CX-z0v7 (condition 2): unified web+bot serve-side session cap
        # (concurrent-total + per-principal backstop). Generous defaults,
        # in-memory/restart-not-durable — see its moduledoc. Safe to start
        # unconditionally alongside SessionViewRegistry above.
        Commonplace.MUD.SessionLimit,
        # CX-nf8p: the THROUGHPUT sibling of SessionLimit — a serve-side
        # ETS token-bucket (per-session + per-principal) consulted at both
        # command entry points before the PlayerSession mailbox. Owns its
        # public ETS table + one idle-sweep timer; same in-memory,
        # restart-not-durable scope. Safe to start unconditionally.
        Commonplace.MUD.RateLimit
      ] ++
        snapshot_sweeper_children() ++
        presence_reaper_children() ++
        compute_rehydrator_children() ++
        federation_pull_children() ++
        orchestrator_children() ++
        bursar_children() ++
        reflog_children() ++
        ghost_reaper_children() ++
          git_bridge_children() ++
          workspace_lock_children(data_dir) ++ scheduler_children()

    opts = [strategy: :one_for_one, name: Commonplace.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # CX-vyrs: log the resolved effective-enforcement posture once per
        # boot — cheap (one Application.get_env read apiece + a trust.json
        # read), unconditional (it's just a log line), and it's the one
        # place an operator/log-scraper can confirm which of the three
        # independently-staged knobs (trust-anchor strictness, local-write,
        # local-read) actually took effect on THIS node.
        Logger.info("Commonplace.Trust posture at boot: #{inspect(Commonplace.Trust.posture())}")

        # CX-38fw (M4 sub-bead i): boot-time idempotent template ensure.
        # Mints /chat/__template/ on first boot; no-op on subsequent
        # boots. Skipped when no workspace root exists (fresh installs,
        # test runs without a seeded root) — mirrors the
        # presence_reaper_children/0 pattern.
        ensure_chat_template_if_workspace_present()
        # CX-xs2d: boot-time idempotent doc-hosting manifest ensure —
        # mirrors ensure_chat_template_if_workspace_present/0 immediately
        # above (CX-38fw pattern: run-if-workspace-root-resolves, no-op
        # otherwise). Without this, `:mud_engine_manifest` stays empty
        # after every serve restart until a session fires
        # `Commonplace.MUD.Bootstrap.seed/2`, so every doc-hosted verb
        # silently runs on its compiled-in floor in the meantime. Root
        # presence is used only as the "this node has a real workspace"
        # signal — `ensure_doc_manifests/1` itself doesn't need the root.
        ensure_mud_doc_manifests_if_workspace_present()

        # CX-fml6 (discovery half): Mode-B parity with Mode A's node_name
        # write. Mode A (`commonplace_cli`'s Serve, apps/commonplace_cli/lib/
        # commonplace/cli/serve.ex) writes `<data_dir>/node_name` after
        # `Node.start` and removes it on shutdown. Mode B (Phoenix-as-serve,
        # `mix phx.server` with `--sname`) boots through this Application
        # callback instead and, until now, wrote nothing — the same
        # Mode-A/Mode-B parity trap as CX-nyvm's `bursar_on_boot` gap, where
        # a Mode-B-only omission was invisible until something that
        # depended on it (there: every move; here: MCP serve discovery)
        # broke. Both boot paths must agree on what they publish.
        maybe_write_node_name(data_dir)

        {:ok, pid}

      other ->
        other
    end
  end

  @doc false
  # See the CX-fml6 comment at the call site in `start/2` above for the
  # Mode-A/Mode-B parity rationale. Extracted to a public function so it's
  # directly testable (`mode_b_node_name_test.exs`) without booting the
  # full application.
  #
  # Gated on the SAME signal `workspace_lock_children/1` uses
  # (`:workspace_lock_on_boot`) — that flag already means "this process is
  # a `commonplace serve` (Mode A or Mode B), not a test run / bare `mix
  # run` / library embedding" — plus `Node.alive?/0`, since an unnamed
  # node has no node name worth publishing for RPC discovery.
  #
  # Deliberately does NOT clean up on shutdown: unlike Mode A, Mode B has
  # no reliable shutdown hook here to remove the file, and a stale file
  # left behind by a killed/crashed Mode-B serve is exactly the case
  # CX-fml6 Part 2 (MCP-side `verify_same_workspace/2`) exists to catch —
  # the write side doesn't need to be perfect if the read side verifies.
  #
  # Must not be able to crash boot: a serve that cannot write a discovery
  # hint file must still serve. Errors are caught and logged at :warning.
  def maybe_write_node_name(data_dir) do
    do_maybe_write_node_name(
      data_dir,
      Node.alive?(),
      Application.get_env(:commonplace, :workspace_lock_on_boot, false),
      Node.self()
    )
  end

  # The gating + write decision, with `alive?`/`gate?`/`node_name` taken
  # as explicit arguments rather than read live. This is what
  # `mode_b_node_name_test.exs` exercises directly — it lets the "gate on
  # AND node alive" branch be tested without the test suite itself
  # starting real BEAM distribution (Node.start/Node.stop), which is out
  # of bounds for this codebase's test process per the CX-fml6 execution
  # constraints (starting/stopping nodes from a test can collide with a
  # live serve on the same box). `maybe_write_node_name/1` above is the
  # thin, non-testable wrapper that supplies the real values.
  @doc false
  def do_maybe_write_node_name(data_dir, alive?, gate?, node_name) do
    if alive? and gate? do
      path = Path.join(data_dir, "node_name")

      try do
        case File.write(path, Atom.to_string(node_name)) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Commonplace.Application: could not write #{path} (#{inspect(reason)}); " <>
                "MCP serve discovery via <data_dir>/node_name will not find this node"
            )

            :ok
        end
      rescue
        e ->
          Logger.warning(
            "Commonplace.Application: writing #{path} raised #{inspect(e)}; " <>
              "MCP serve discovery via <data_dir>/node_name will not find this node"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp ensure_chat_template_if_workspace_present do
    case Commonplace.Workspace.root_uuid() do
      {:ok, root_uuid} ->
        Commonplace.Chat.TemplateBootstrap.ensure_template(root_uuid)

      {:error, _} ->
        :ok
    end
  end

  # `:mud_manifest_on_boot` (default TRUE — this hook exists so a Mode-B
  # serve restart is doc-hosting-durable) is set FALSE in config/test.exs,
  # same pattern as `:snapshot_sweeper_enabled`: the test env's global
  # store (`tmp/test_data`) PERSISTS across suite runs, so a boot-time
  # ensure would populate `:mud_engine_manifest` from suite start and
  # every test would resolve doc-hosted verbs against whatever (possibly
  # stale, seeded-by-older-code) docs that store carries at the fixed
  # engine UUIDs — behavior tests must exercise the compiled floors unless
  # they seed their own docs deliberately.
  defp ensure_mud_doc_manifests_if_workspace_present do
    with true <- Application.get_env(:commonplace, :mud_manifest_on_boot, true),
         {:ok, _} <- Commonplace.Workspace.root_uuid() do
      Commonplace.MUD.Bootstrap.ensure_doc_manifests()
    else
      _ -> :ok
    end
  end

  @doc false
  # CX-fab5: periodic snapshot sweep over every doc in the local
  # CommitStore. Composes safely with the producer-side hook (CX-tvyb)
  # and the explicit CLI command (CX-2ok0) — concurrent snapshot
  # attempts at the same parent dedup via CX-umz. Default-on in dev/prod;
  # default-off in test (see config/test.exs) so async snapshot writes
  # don't race with test isolation.
  def snapshot_sweeper_children do
    if Application.get_env(:commonplace, :snapshot_sweeper_enabled, true) do
      [{Commonplace.SnapshotSweeper, []}]
    else
      []
    end
  end

  @doc false
  # GitBridge-on-boot (CX-b0ow.1): the durable-mapping condition — a git
  # mirror that silently stays down after a node reboot is worse than no
  # mirror, because it LOOKS covered. The supervisor reads
  # `<data_dir>/git_bridges.json` at boot and starts one bridge per
  # persisted mapping (absent/empty file ⇒ zero children, so this is
  # free until `add_mapping/2` is first used). Each bridge start emits a
  # `:started` red event, so boot gaps are visible. Default-off only in
  # test (config/test.exs) to keep suite runs from touching a shared
  # mapping file.
  def git_bridge_children do
    if Application.get_env(:commonplace, :git_bridge_on_boot, true) do
      [{Commonplace.GitBridge.Supervisor, [store: Commonplace.Store.CommitStoreClient]}]
    else
      []
    end
  end

  @doc false
  # Orchestrator-on-boot (CX-tdkq.12, O2): DOUBLE-GATED — the embedder
  # must explicitly opt in (`:orchestrator_on_boot`, default false) AND
  # the workspace root must resolve. Running declared processes is a
  # trust-boundary decision, not a supervision detail: web/MCP/bots/CLI
  # one-shots and tests never auto-execute substrate code unless they
  # deliberately configure it. `commonplace serve` opts in.
  def orchestrator_children do
    enabled = Application.get_env(:commonplace, :orchestrator_on_boot, false)

    case {enabled, Commonplace.Workspace.root_uuid()} do
      {true, {:ok, _root}} ->
        [
          %{
            id: Commonplace.Process.Orchestrator,
            start:
              {Commonplace.Process.Orchestrator, :start_link,
               [[root_uuid: :workspace, name: Commonplace.Process.Orchestrator]]},
            restart: :permanent
          }
        ]

      _ ->
        []
    end
  end

  @doc false
  # Bursar-on-boot (move #4, CX-tdkq.7, B8): DOUBLE-GATED like
  # orchestrator_children/0 — explicit opt-in (`:bursar_on_boot`,
  # default false) AND a resolvable workspace root. The Bursar is the
  # cluster's lock authority and rides the serve node's single-owner
  # designation (the same convention that makes serve the CommitStore
  # owner): only a deliberately-configured embedder (`commonplace
  # serve`) starts one. Everyone else — web, MCP, tests, bare `mix run`
  # temp nodes — reaches it through Commonplace.Green.BursarClient or
  # fails closed. Root is resolved at gate time; a `cp checkout`
  # re-root needs a serve restart to follow (same trade-off the
  # orchestrator makes, acceptable for the serve lifecycle).
  def bursar_children do
    enabled = Application.get_env(:commonplace, :bursar_on_boot, false)

    case {enabled, Commonplace.Workspace.root_uuid()} do
      {true, {:ok, root_uuid}} ->
        [
          %{
            id: Commonplace.Green.Bursar,
            start:
              {Commonplace.Green.Bursar, :start_link,
               [[root_uuid: root_uuid, name: Commonplace.Green.Bursar]]},
            restart: :permanent
          }
        ]

      _ ->
        []
    end
  end

  @doc false
  # Reflog-on-boot (CX-0t2r, recording-half revival): DOUBLE-GATED like
  # bursar_children/0 — explicit opt-in (`:reflog_on_boot`, default
  # false) AND a resolvable workspace root. `Commonplace.Reflog.CheckpointTimer`
  # has existed since the sync-agent era but was never started anywhere on the
  # Mode-B Phoenix serve (no filesystem checkout sync loop to drive it) — see
  # CX-0t2r's hunt finding. Same serve-role convention as bursar/orchestrator:
  # only a deliberately-configured embedder (`commonplace serve` / the Mode-B
  # runtime.exs block) opts in; web/MCP/tests/bare-`mix run` never start a
  # timer. Interval defaults to 5 minutes, overridable via
  # `:reflog_interval_ms`. Started under owner "serve" (see
  # `CheckpointTimer`'s `:reflog_owner` default) — a FRESH lineage under
  # `__reflog/serve/`, deliberately distinct from the dormant April-era
  # `__reflog/server/` tree so a revival doesn't inherit that history's
  # unsigned-write debt.
  def reflog_children do
    enabled = Application.get_env(:commonplace, :reflog_on_boot, false)

    case {enabled, Commonplace.Workspace.root_uuid()} do
      {true, {:ok, root_uuid}} ->
        interval = Application.get_env(:commonplace, :reflog_interval_ms, 300_000)

        [
          %{
            id: Commonplace.Reflog.CheckpointTimer,
            start:
              {Commonplace.Reflog.CheckpointTimer, :start_link,
               [
                 [
                   root_uuid: root_uuid,
                   interval: interval,
                   name: Commonplace.Reflog.CheckpointTimer
                 ]
               ]},
            restart: :permanent
          }
        ]

      _ ->
        []
    end
  end

  @doc false
  # CX-3xwu (A): the continuous ghost-reaper (Commonplace.MUD.GhostReaper).
  # DOUBLE-GATED like bursar_children/0 — explicit opt-in
  # (`:ghost_reaper_on_boot`, default false) AND a resolvable workspace root.
  # Only the serve node (Mode B: COMMONPLACE_DATA_DIR + PHX_SERVER, see
  # config/runtime.exs) opts in; web/MCP/tests/bare-`mix run` never start a
  # reaper. The reaper is node-elevated (it GCs presences as world-owner) and is
  # the highest-hazard component in the presence system, so it is gated behind an
  # explicit flag AND runs ONLY where a node identity + workspace root exist.
  def ghost_reaper_children do
    enabled = Application.get_env(:commonplace, :ghost_reaper_on_boot, false)

    case {enabled, Commonplace.Workspace.root_uuid()} do
      {true, {:ok, root_uuid}} ->
        [
          %{
            id: Commonplace.MUD.GhostReaper,
            start:
              {Commonplace.MUD.GhostReaper, :start_link,
               [[root_uuid: root_uuid, name: Commonplace.MUD.GhostReaper]]},
            restart: :permanent
          }
        ]

      _ ->
        []
    end
  end

  @doc false
  # CX-x073: `Commonplace.Scheduler.Agent` (the userland one-shot
  # scheduler, CX-6av) is a complete, tested GenServer that NOTHING has
  # ever started — no application.ex entry, no non-test `start_link`
  # caller in any of the five apps. Any client sending a `schedule`
  # request on the magenta topic `agents/scheduler` got silence, on
  # every standard boot, since it was written. A fully-tested subsystem
  # that cannot run also misleads readers: a previous architecture
  # review treated its delivery semantics as live.
  #
  # ⚠️ NOTE THE NAME COLLISION that helped it hide. `Commonplace.SnapshotWorker`
  # is described in the children list above as the "single-flight
  # scheduler" (CX-tdkq.4) and IS started. It is a different thing
  # entirely — reader-side lazy-snapshot debounce, not this. Grepping
  # application.ex for "scheduler" finds the started one.
  #
  # DOUBLE-GATED exactly like ghost_reaper_children/0: explicit opt-in
  # AND a resolvable workspace root.
  #
  # It rides its OWN env var, default OFF, deliberately — the CX-0t2r
  # deploy lesson. This agent FIRES TIMERS and WRITES a CRDT doc
  # (`__system/scheduler`), so it is world-MUTATING, not a serve-role
  # descriptor like the bursar/lock/reaper flags it sits beside. Putting
  # it in the same block as those would make "deploy the code" and "start
  # writing schedules into the live store" the same event, which is
  # exactly how a deliberately staged deploy got silently collapsed
  # before. Shipping this wiring changes NO existing boot: every current
  # launch omits the var and gets the same behaviour as before.
  #
  # This does not decide the bead's (a)-wire-it-up vs (b)-delete
  # question. It makes the launch path EXIST and be documented, so the
  # subsystem is reachable deliberately instead of unreachable silently.
  # Deleting it remains open and is a separate call.
  #
  # ⚠️ Its own moduledoc says "run at most one per workspace"; leader
  # election is a future bead. On a clustered serve, enabling this on
  # more than one node would run more than one. Single-node only until
  # that lands.
  def scheduler_children do
    enabled = Application.get_env(:commonplace, :scheduler_on_boot, false)

    case {enabled, Commonplace.Workspace.root_uuid()} do
      {true, {:ok, root_uuid}} ->
        [
          %{
            id: Commonplace.Scheduler.Agent,
            start:
              {Commonplace.Scheduler.Agent, :start_link,
               [[root_uuid: root_uuid, name: Commonplace.Scheduler.Agent]]},
            restart: :permanent
          }
        ]

      _ ->
        []
    end
  end

  @doc false
  # Workspace single-owner lock (CX-qida): an OS advisory flock(2) on
  # `<data_dir>/serve.lock`, held for the process lifetime by
  # `Commonplace.Workspace.Lock`. DOUBLE-GATED like orchestrator_children/0
  # and bursar_children/0 above — explicit opt-in
  # (`:workspace_lock_on_boot`, default false). Bare `mix test`, library
  # embedding, and one-shot CLI commands never set this flag and never
  # take the lock; only `commonplace serve` and the Phoenix-as-serve
  # Mode B boot path (COMMONPLACE_DATA_DIR + PHX_SERVER, see
  # config/runtime.exs) opt in — both are "this process owns the
  # workspace" declarations, not supervision details. Unlike the
  # orchestrator/bursar gates this one does NOT also require a
  # resolvable workspace root: the corruption this guards against
  # (two CubDB writers on one data_dir) can happen even before a root
  # file exists (e.g. mid-`commonplace init`), so it gates on data_dir
  # alone.
  def workspace_lock_children(data_dir) do
    if Application.get_env(:commonplace, :workspace_lock_on_boot, false) do
      [{Commonplace.Workspace.Lock, data_dir: data_dir}]
    else
      []
    end
  end

  @doc false
  # Federation pull client (phase C, CX-orfw): started ONLY when peers
  # are explicitly configured — federation is off by default.
  #
  #     config :commonplace, :federation_pull,
  #       interval_ms: 30_000, peers: [%{name:, base_url:, token:, docs:}]
  def federation_pull_children do
    case Application.get_env(:commonplace, :federation_pull) do
      %{peers: [_ | _] = peers} = cfg ->
        [{Commonplace.Federation.PullClient,
          peers: peers, interval_ms: Map.get(cfg, :interval_ms, 30_000)}]

      _ ->
        []
    end
  end

  @doc false
  # Return reaper child specs only when a workspace root UUID is configured.
  #
  # The reaper scans the workspace root schema for stale presence entries. In
  # environments without a workspace (test runs, fresh installs), there is no
  # `<data_dir>/root` file and we skip starting the reaper entirely.
  def presence_reaper_children do
    case Commonplace.Workspace.root_uuid() do
      {:ok, _root_uuid} ->
        # CX-4wl: omit a static :root_uuid so the reaper resolves the
        # workspace root each scan tick. Booting only when a root file
        # exists keeps the no-workspace cases (test runs, fresh installs)
        # from launching a useless reaper, but in the long-running case
        # we want it to follow `cp checkout` rerooting without a restart.
        [
          %{
            id: Commonplace.Presence.ReaperSupervisor,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [
                 [{Commonplace.Presence.Reaper, []}],
                 [
                   strategy: :one_for_one,
                   name: Commonplace.Presence.ReaperSupervisor
                 ]
               ]}
          }
        ]

      {:error, _} ->
        []
    end
  end

  @doc false
  # CX-tdkq.3 (architecture-review R3): resume chat view-computes on boot so
  # computed views survive a BEAM restart without a human re-opening each
  # room. Appended after ChatViewComputeSupervisor (whose DynamicSupervisor +
  # ETS index it drives) so the dependency is up first. Workspace-gated like
  # the presence Reaper — no rehydrator on test runs / fresh installs. Root is
  # resolved dynamically at scan time, so a `cp checkout` re-root is followed.
  def compute_rehydrator_children do
    case Commonplace.Workspace.root_uuid() do
      {:ok, _root_uuid} ->
        [{Commonplace.Chat.ComputeRehydrator, []}]

      {:error, _} ->
        []
    end
  end
end
