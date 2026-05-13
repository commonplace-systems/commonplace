defmodule Commonplace.Bots.Worker.Tools.ReadMemory do
  @moduledoc """
  `read_memory` tool — return the most recent N lines of the
  bot's `memory.jsonl`, optionally filtered by a substring
  on the `text` field.

  Memory lines are JSON objects. The tool returns them parsed
  (as a JSON array). Lines that fail to parse are dropped
  silently — corrupted history shouldn't be the bot's
  problem to debug.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  @default_limit 20
  @max_limit 200

  def name, do: "read_memory"

  def definition do
    %{
      "name" => "read_memory",
      "description" =>
        "Read recent lines of your memory.jsonl. Returns a JSON array of memory entries.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max lines (default 20, max 200).",
            "minimum" => 1,
            "maximum" => @max_limit
          },
          "contains" => %{
            "type" => "string",
            "description" =>
              "Optional substring; only memory lines whose 'text' field contains it are returned."
          }
        }
      }
    }
  end

  def call(state, input) do
    limit = input |> Map.get("limit", @default_limit) |> clamp()
    contains = Map.get(input, "contains")

    store = Keyword.get(state.opts, :store, CommitStoreClient)
    memory_uuid = state.entity.memory_uuid

    with {:ok, doc} <- DocBuilder.reconstruct_snapshot(store, memory_uuid) do
      text = ContentType.get_content(doc) || ""

      entries =
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&safe_decode/1)
        |> Enum.reject(&is_nil/1)
        |> filter_contains(contains)
        |> Enum.take(-limit)

      {:ok, Jason.encode!(entries)}
    else
      _ -> {:error, "memory doc unreadable"}
    end
  end

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp(_), do: @default_limit

  defp safe_decode(line) do
    case Jason.decode(line) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  defp filter_contains(entries, nil), do: entries
  defp filter_contains(entries, ""), do: entries

  defp filter_contains(entries, needle) do
    Enum.filter(entries, fn e ->
      case Map.get(e, "text") do
        t when is_binary(t) -> String.contains?(t, needle)
        _ -> false
      end
    end)
  end
end
