defmodule Commonplace.CLI.Init do
  @moduledoc "Initialize a new commonplace workspace."

  alias Commonplace.CLI

  def run(data_dir, _args) do
    if CLI.root_uuid(data_dir) do
      IO.puts("Workspace already initialized at #{data_dir}")
      System.halt(1)
    end

    CLI.ensure_started(data_dir)

    {:ok, %{root_uuid: root_uuid}} = Commonplace.Workspace.initialize(data_dir)

    IO.puts("Initialized commonplace workspace at #{data_dir}")
    IO.puts("Root: #{root_uuid}")
  end
end
