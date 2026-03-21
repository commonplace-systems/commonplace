defmodule Commonplace.CLI do
  @moduledoc """
  Git-style CLI for commonplace.

  Usage: commonplace <command> [args]

  Commands:
    init           Initialize a new commonplace workspace
    ls [path]      List directory contents
    cat <path>     Show document content
    import <dir>   Import files from disk into the document tree
  """

  def main(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        strict: [data_dir: :string, help: :boolean],
        aliases: [d: :data_dir, h: :help]
      )

    if opts[:help] do
      IO.puts(@moduledoc)
      System.halt(0)
    end

    data_dir = opts[:data_dir] || default_data_dir()

    case args do
      ["init" | rest] ->
        Commonplace.CLI.Init.run(data_dir, rest)

      ["ls" | rest] ->
        Commonplace.CLI.Ls.run(data_dir, rest)

      ["cat" | rest] ->
        Commonplace.CLI.Cat.run(data_dir, rest)

      ["import" | rest] ->
        Commonplace.CLI.Import.run(data_dir, rest)

      [] ->
        IO.puts(@moduledoc)

      [cmd | _] ->
        IO.puts(:stderr, "Unknown command: #{cmd}")
        IO.puts(:stderr, "Run 'commonplace --help' for usage.")
        System.halt(1)
    end
  end

  @doc "Start the application services needed for CLI commands."
  def ensure_started(data_dir) do
    File.mkdir_p!(data_dir)

    # Ensure the commonplace application is started
    Application.put_env(:commonplace, :data_dir, data_dir)
    {:ok, _} = Application.ensure_all_started(:commonplace)
    :ok
  end

  @doc "Load a schema doc from the commit store."
  def load_schema(uuid) do
    alias Commonplace.Store.CommitStore
    alias Commonplace.Tree.Schema

    case CommitStore.latest_commit(uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  @doc "Get the root UUID for this workspace."
  def root_uuid(data_dir) do
    meta_path = Path.join(data_dir, "root")

    case File.read(meta_path) do
      {:ok, uuid} -> String.trim(uuid)
      {:error, _} -> nil
    end
  end

  @doc "Set the root UUID for this workspace."
  def set_root_uuid(data_dir, uuid) do
    File.write!(Path.join(data_dir, "root"), uuid)
  end

  defp default_data_dir do
    Path.join(File.cwd!(), ".commonplace")
  end
end
