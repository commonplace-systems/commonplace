defmodule Commonplace.Bots.Worker.Tools.ReadMemory do
  @moduledoc """
  `read_memory` tool — return the most recent N entries of the bot's memory
  LOG, optionally filtered by a substring on the `text` field.

  Memory now lives UNDER the bot's home as a zoned note-meta (`home/memory/`,
  C3d) whose `__note.json` carries an `"entries"` array — the source of truth
  is `state.mud_ctx.home_room_uuid`, NOT the old entity `memory.jsonl`. A bot
  with no `mud_ctx` (unprovisioned) reads an empty log gracefully.

  Entries are JSON objects; the tool returns them as a JSON array.
  """

  alias Commonplace.Bots.NoteDoc

  @memory_dir "memory"
  @empty_entries ~s({"entries":[]})
  @default_limit 20
  @max_limit 200

  def name, do: "read_memory"

  def definition do
    %{
      "name" => "read_memory",
      "description" =>
        "Read recent entries of your memory log. Returns a JSON array of memory entries.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max entries (default 20, max 200).",
            "minimum" => 1,
            "maximum" => @max_limit
          },
          "contains" => %{
            "type" => "string",
            "description" =>
              "Optional substring; only memory entries whose 'text' field contains it are returned."
          }
        }
      }
    }
  end

  def call(%{mud_ctx: ctx}, input) when is_map(ctx) do
    limit = input |> Map.get("limit", @default_limit) |> clamp()
    contains = Map.get(input, "contains")

    case NoteDoc.ensure_zoned_dir(ctx.home_room_uuid, @memory_dir, @empty_entries, ctx) do
      {:ok, mem_uuid} ->
        entries =
          mem_uuid
          |> NoteDoc.read_entries(ctx)
          |> filter_contains(contains)
          |> Enum.take(-limit)

        {:ok, Jason.encode!(entries)}

      {:error, _} ->
        {:error, "memory unreadable"}
    end
  end

  # No MUD ctx — no home to read from. Graceful empty log.
  def call(_state, _input), do: {:ok, "[]"}

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp(_), do: @default_limit

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
