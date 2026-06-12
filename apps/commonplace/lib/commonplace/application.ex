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
        %{
          id: Commonplace.Store.CommitStoreSupervisor,
          type: :supervisor,
          start:
            {Supervisor, :start_link,
             [
               [{Commonplace.Store.CommitStore, data_dir: data_dir}],
               [
                 strategy: :one_for_one,
                 max_restarts: 2,
                 max_seconds: 10,
                 name: Commonplace.Store.CommitStoreSupervisor
               ]
             ]}
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
        Commonplace.MUD.MoveServer,
        Commonplace.MUD.TickBot
      ] ++
        snapshot_sweeper_children() ++
        presence_reaper_children() ++
        compute_rehydrator_children() ++
        federation_pull_children() ++ orchestrator_children()

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
