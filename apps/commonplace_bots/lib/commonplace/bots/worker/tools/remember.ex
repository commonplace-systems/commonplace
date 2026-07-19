defmodule Commonplace.Bots.Worker.Tools.Remember do
  @moduledoc """
  `remember` tool — append one entry to the bot's memory LOG.

  v0 schema for the appended entry:

      { "ts": "<iso8601>",
        "text": "<the remembered text>",
        "source_msg_id": "<id of message that triggered the turn, if any>" }

  `kind` is reserved (per the converged sketch's optional-keys list)
  but not emitted by the v0 tool.

  ## Anchored under the bot's HOME (lands under enforce — C3d)

  Memory is NO LONGER a `memory.jsonl` in the entity dir (outside the bot's cert
  scope → denied under `local_write_gate: :enforce`). It is a ZONED NOTE-META
  dir `home/memory/` whose `__note.json` carries an `"entries"` array. Because it
  sits in the bot's home zone, the bot's `{:subtree, home}[:write]` cert covers
  every append, so a remember LANDS under enforce. Appends are a zone-preserving
  RMW push onto the array (`NoteDoc.append_entry` → `World.merge_meta`, never a
  struct round-trip — CX-cl65). Resolved from `state.mud_ctx.home_room_uuid`; a
  bot with no `mud_ctx` (unprovisioned / not in the world) fails closed.
  """

  alias Commonplace.Bots.NoteDoc

  @memory_dir "memory"
  @empty_entries ~s({"entries":[]})

  def name, do: "remember"

  def definition do
    %{
      "name" => "remember",
      "description" =>
        "Append a memory entry to your private memory log. Persists across turns; readable via read_memory.",
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

  def call(%{mud_ctx: ctx} = state, %{"text" => text})
      when is_map(ctx) and is_binary(text) and text != "" do
    entry = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "text" => text,
      "source_msg_id" => state |> Map.get(:event, %{}) |> Map.get("message_id")
    }

    with {:ok, mem_uuid} <-
           NoteDoc.ensure_zoned_dir(ctx.home_room_uuid, @memory_dir, @empty_entries, ctx),
         :ok <- NoteDoc.append_entry(mem_uuid, entry, ctx) do
      {:ok, "remembered"}
    else
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, inspect(other)}
    end
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx),
    do: {:error, "remember requires a non-empty 'text' field"}

  # No MUD ctx — not in the world, no home to remember under. Fail closed.
  def call(_state, _input), do: {:error, "You are not in the world."}
end
