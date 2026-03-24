defmodule Commonplace.CLI.Init do
  @moduledoc "Initialize a new commonplace workspace."

  alias Commonplace.CLI
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStoreClient, as: CommitStore
  alias Commonplace.Sync.CheckoutRegistry

  def run(data_dir, _args) do
    if CLI.root_uuid(data_dir) do
      IO.puts("Workspace already initialized at #{data_dir}")
      System.halt(1)
    end

    CLI.ensure_started(data_dir)

    # Create root schema doc
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(root_uuid, update, nil)

    CLI.set_root_uuid(data_dir, root_uuid)

    # Register the workspace directory as the first checkout
    workspace_dir = Path.dirname(data_dir)
    config_path = Path.join(data_dir, "checkouts.json")

    {:ok, registry} =
      CheckoutRegistry.start_link(
        config_path: config_path,
        store: Commonplace.Store.CommitStore
      )

    CheckoutRegistry.register(registry, workspace_dir, root_uuid, :dir)

    IO.puts("Initialized commonplace workspace at #{data_dir}")
    IO.puts("Root: #{root_uuid}")
  end
end
