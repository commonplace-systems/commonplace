defmodule Commonplace.Bots.Worker.Tools.Remember do
  @moduledoc """
  `remember` tool — append a JSON line to the bot's `memory.jsonl`.

  v0 schema for the appended line:

      { "ts": "<iso8601>",
        "text": "<the remembered text>",
        "source_msg_id": "<id of message that triggered the turn, if any>" }

  `kind` is reserved (per the converged sketch's optional-keys list)
  but not emitted by the v0 tool. Future tool calls can include it
  via an `input.kind` field once the model is taught about it.

  Storage shape: the bot's `memory.jsonl` is a text doc; the tool
  reads its current content, computes the end-of-document index,
  and inserts a newline + the JSON line. Concurrent appends are
  safe under YText semantics (two end-inserts get distinct positions).
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder

  def name, do: "remember"

  def definition do
    %{
      "name" => "remember",
      "description" =>
        "Append a memory line to your private memory.jsonl. Persists across turns; readable via read_memory.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The thing to remember. One line, free-form text."
          }
        },
        "required" => ["text"]
      }
    }
  end

  def call(state, %{"text" => text}) when is_binary(text) and text != "" do
    memory_uuid = state.entity.memory_uuid

    entry = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "text" => text,
      "source_msg_id" => Map.get(state.event, "message_id")
    }

    line = Jason.encode!(entry) <> "\n"

    case append_to_memory(memory_uuid, line, state) do
      :ok -> {:ok, "remembered"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(_state, _input), do: {:error, "remember requires a non-empty 'text' field"}

  defp append_to_memory(memory_uuid, line, state) do
    store = Keyword.get(state.opts, :store, CommitStoreClient)
    store_for_writes = Keyword.get(state.opts, :write_store, CommitStore)

    with {:ok, doc} <- DocBuilder.reconstruct_snapshot(store, memory_uuid),
         doc <- ContentType.insert_text(doc, end_index(doc), line) do
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(store_for_writes, memory_uuid, update)
      :ok
    else
      :none ->
        {:error, :memory_doc_missing}

      {:error, _} = err ->
        err
    end
  end

  defp end_index(doc) do
    case ContentType.get_content(doc) do
      nil -> 0
      text when is_binary(text) -> String.length(text)
      _ -> 0
    end
  end
end
