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
      ] ++ presence_reaper_children()

    opts = [strategy: :one_for_one, name: Commonplace.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  # Return reaper child specs only when a workspace root UUID is configured.
  #
  # The reaper scans the workspace root schema for stale presence entries. In
  # environments without a workspace (test runs, fresh installs), there is no
  # `<data_dir>/root` file and we skip starting the reaper entirely.
  def presence_reaper_children do
    case Commonplace.Workspace.root_uuid() do
      {:ok, root_uuid} ->
        [
          %{
            id: Commonplace.Presence.ReaperSupervisor,
            type: :supervisor,
            start:
              {Supervisor, :start_link,
               [
                 [{Commonplace.Presence.Reaper, [root_uuid: root_uuid]}],
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
