defmodule Commonplace.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    children = [
      {Registry, keys: :unique, name: Commonplace.Document.Registry},
      {Phoenix.PubSub, name: Commonplace.PubSub},
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
      {DynamicSupervisor, name: Commonplace.Document.Supervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Commonplace.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
