defmodule Commonplace.CLI.Export do
  @moduledoc "Export the document tree to a directory on disk."

  alias Commonplace.CLI
  alias Commonplace.Sync.Export

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      [] ->
        IO.puts(:stderr, "Usage: commonplace export <directory>")
        System.halt(1)

      [output_dir | _] ->
        Export.export(root, output_dir)
        IO.puts("Exported to #{output_dir}")
    end
  end
end
