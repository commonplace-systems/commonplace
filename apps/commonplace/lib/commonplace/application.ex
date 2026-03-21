defmodule Commonplace.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    children = [
      {Registry, keys: :unique, name: Commonplace.Document.Registry},
      {Phoenix.PubSub, name: Commonplace.PubSub},
      {Commonplace.Store.CommitStore, data_dir: data_dir},
      {DynamicSupervisor, name: Commonplace.Document.Supervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Commonplace.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
