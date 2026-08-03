defmodule Commonplace.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
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

    # CX-hilo: durable trust-decision audit trail. Bridges the three
    # trust-rejection telemetry events (rejected local write, ignored
    # revocation, would-refuse dry-run read) into a red-log doc so a
    # security-incident review has a data source beyond "who was
    # tailing the live log at the time." Idempotent attach, same
    # detach/attach idiom as the reflog dirty-tracker above. See
    # `Commonplace.Trust.AuditLog` moduledoc for the flood guard and
    # retention story.
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
        ghost_reaper_children() ++ git_bridge_children() ++ workspace_lock_children(data_dir)

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
        {:ok, pid}

      other ->
        other
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
