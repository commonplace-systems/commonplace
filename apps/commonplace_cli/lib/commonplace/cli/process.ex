defmodule Commonplace.CLI.Process do
  @moduledoc """
  CLI verb `process` — manage entries in the workspace's
  `__processes.json` CRDT doc.

  v1 (CX-didr) ships one subcommand: `remove`. The point is to
  avoid the standalone-script-vs-serve-dist-Erlang debugging
  trap (Application.put_env timing pitfall — see CX-0nkq) when
  the only thing you actually need is to drop a misbehaving
  process entry.

      commonplace process remove <name>

  Scope: edits `<root>/__processes.json` only. The orchestrator
  ALSO walks sub-dir `__processes.json` files
  (`collect_processes_recursive`); removing from sub-dirs is out
  of scope for v1 — a `--dir` flag can land later.

  Idempotent: removing a non-existent name is a no-op with a
  friendly message and exit 0. The orchestrator polls
  `__processes.json` on its own cadence; no manual reload signal
  needed.
  """

  alias Commonplace.CLI
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.{Doc, Encoding}

  @processes_doc "__processes.json"

  @doc """
  Subcommand entry. Returns the exit code (0 success, 64 usage)
  so the top-level `Commonplace.CLI.main/1` can `System.halt/1` —
  this avoids killing the BEAM inside an in-process test driver.
  """
  @spec run(Path.t(), String.t(), [String.t()]) :: non_neg_integer()
  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)

    case args do
      ["remove", name | _] -> remove(data_dir, name)
      ["remove"] -> usage("missing <name> argument")
      [] -> usage("missing subcommand")
      [other | _] -> usage("unknown subcommand: #{other}")
    end
  end

  defp usage(reason) do
    IO.puts(:stderr, "commonplace process: #{reason}")
    IO.puts(:stderr, "usage: commonplace process remove <name>")
    64
  end

  defp remove(data_dir, name) do
    root_uuid = CLI.root_uuid(data_dir)

    case load_processes_doc(root_uuid) do
      :no_processes_doc ->
        IO.puts("No __processes.json at root — nothing to remove.")
        0

      {:ok, processes_uuid, doc, json_map} ->
        case Map.has_key?(json_map, name) do
          false ->
            IO.puts(~s|No process named "#{name}" — nothing to remove.|)
            0

          true ->
            new_map = Map.delete(json_map, name)
            write_processes_doc(processes_uuid, doc, new_map)

            remaining =
              case map_size(new_map) do
                0 -> "no processes remain."
                1 -> "1 process remains."
                n -> "#{n} processes remain."
              end

            IO.puts(~s|Removed "#{name}"; #{remaining}|)
            IO.puts("The running serve daemon will pick up the change on its next sync tick.")
            0
        end
    end
  end

  defp load_processes_doc(root_uuid) do
    with {:ok, root_doc} <- DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid),
         {:ok, entry} <- Schema.get_entry(root_doc, @processes_doc),
         {:ok, doc} <- DocBuilder.reconstruct_snapshot(CommitStoreClient, entry.node_id) do
      text = ContentType.get_content(doc) || "{}"

      case Jason.decode(text) do
        {:ok, %{} = map} -> {:ok, entry.node_id, doc, map}
        _ -> {:error, :malformed_processes_json}
      end
    else
      :error -> :no_processes_doc
      :none -> :no_processes_doc
      other -> other
    end
  end

  defp write_processes_doc(uuid, _old_doc, new_map) do
    # Rebuild the text doc from scratch with the new JSON content.
    # Same shape used by chat/template_bootstrap when minting
    # initial text docs. The old doc's CRDT history is reachable
    # through the commit chain; we just don't carry forward the
    # YText edit history here — `__processes.json` is structured
    # data, not collaborative prose, so an overwrite is fine.
    new_doc = Doc.new() |> ContentType.create(:text, @processes_doc)
    text = Jason.encode!(new_map, pretty: true) <> "\n"
    new_doc = ContentType.insert_text(new_doc, 0, text)
    update = Encoding.encode_update(new_doc)
    CommitStore.create_chained_commit(CommitStore, uuid, update)
  end
end
