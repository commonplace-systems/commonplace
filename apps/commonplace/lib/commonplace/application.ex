defmodule Commonplace.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # :xmerl is used by Commonplace.Document.ViewXml for parsing view XML
    # documents. Ensure it's loaded at app start so `mix phx.server` and
    # other dev-mode entry points don't require a cold restart after the
    # dep is first added.
    _ = Application.ensure_all_started(:xmerl)

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
        Commonplace.MUD.SessionViewRegistry
      ] ++
        snapshot_sweeper_children() ++
        presence_reaper_children() ++
        compute_rehydrator_children() ++
        federation_pull_children() ++
        orchestrator_children() ++
        bursar_children() ++ git_bridge_children() ++ workspace_lock_children(data_dir)

    opts = [strategy: :one_for_one, name: Commonplace.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # CX-38fw (M4 sub-bead i): boot-time idempotent template ensure.
        # Mints /chat/__template/ on first boot; no-op on subsequent
        # boots. Skipped when no workspace root exists (fresh installs,
        # test runs without a seeded root) — mirrors the
        # presence_reaper_children/0 pattern.
        ensure_chat_template_if_workspace_present()
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
