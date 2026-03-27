defmodule Commonplace.CLI.Who do
  @moduledoc "List actors (presence files) in the current directory."

  alias Commonplace.CLI
  alias Commonplace.Presence
  alias Commonplace.Presence.Identity
  alias Commonplace.Tree.Schema

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    run_with_store(root, Commonplace.Store.CommitStore, args)
  end

  @doc "Run with explicit store (for testing)."
  def run_with_store(root_uuid, store, args \\ []) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [type: :string, all: :boolean],
        aliases: [t: :type, a: :all]
      )

    type_filter =
      case opts[:type] do
        nil -> :all
        t -> String.to_existing_atom(t)
      end

    if opts[:all] do
      show_cold_identities(root_uuid, store, type_filter)
    else
      show_hot_presence(root_uuid, store, type_filter)
    end
  end

  defp show_hot_presence(root_uuid, store, type_filter) do
    root_doc = load_schema(root_uuid, store)
    actors = Presence.discover(root_doc, type_filter)

    if Enum.empty?(actors) do
      IO.puts("No actors present.")
    else
      Enum.each(actors, fn entry ->
        IO.puts(entry.name)
      end)
    end
  end

  defp show_cold_identities(root_uuid, store, type_filter) do
    identities = Identity.list(root_uuid, store)

    filtered =
      if type_filter == :all do
        identities
      else
        Enum.filter(identities, fn entry ->
          case Presence.parse_honorific(entry.name) do
            {:ok, _, t} -> t == type_filter
            :error -> false
          end
        end)
      end

    if Enum.empty?(filtered) do
      IO.puts("No actors registered.")
    else
      Enum.each(filtered, fn entry ->
        IO.puts(entry.name)
      end)
    end
  end

  defp load_schema(uuid, store) do
    case Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
