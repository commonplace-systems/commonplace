defmodule Commonplace.CLI.Checkouts do
  @moduledoc """
  List active checkouts in the workspace.
  """

  alias Commonplace.CLI
  alias Commonplace.Sync.CheckoutRegistry

  def run(data_dir, _relative_path, _args) do
    CLI.ensure_started(data_dir)
    registry = start_registry(data_dir)
    checkouts = CheckoutRegistry.list(registry)

    if checkouts == [] do
      IO.puts("No active checkouts.")
    else
      Enum.each(checkouts, fn co ->
        IO.puts("#{co.sync_dir}  →  #{co.uuid}  [#{co.type}]")
      end)
    end
  end

  defp start_registry(data_dir) do
    config_path = Path.join(data_dir, "checkouts.json")

    {:ok, pid} =
      CheckoutRegistry.start_link(
        config_path: config_path,
        store: Commonplace.Store.CommitStore
      )

    pid
  end
end
