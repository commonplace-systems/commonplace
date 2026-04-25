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
        Commonplace.CommandRouter
      ] ++ snapshot_sweeper_children() ++ presence_reaper_children()

    opts = [strategy: :one_for_one, name: Commonplace.Supervisor]
    Supervisor.start_link(children, opts)
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
end
