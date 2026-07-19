defmodule Commonplace.Bots.Worker.Tools.UpdateAgenda do
  @moduledoc """
  `update_agenda` tool (Camillo C3b) — append an item to the bot's
  `agenda.jsonl` (its "desk"), bot-signed.

  This is the heartbeat turn's *write-back*: after doing (or deferring)
  one agenda item, the bot records what it still means to get to. The
  appended line schema is minimal:

      { "ts": "<iso8601>", "text": "<the pending item>" }

  Like every C3a tool this is allowlisted: a bot only gets it if its
  grantor-signed charter grants `"update_agenda"`. The item lands in the bot's
  `home/agenda/` note-meta (C3d) via `Commonplace.Bots.Agenda.append/2` — the
  same zoned, bot-signed, home-anchored primitive `remember` uses, resolved from
  `state.mud_ctx`. A bot with no `mud_ctx` (unprovisioned) refuses gracefully.
  """

  alias Commonplace.Bots.Agenda

  def name, do: "update_agenda"

  def definition do
    %{
      "name" => "update_agenda",
      "description" =>
        "Append an item to your agenda.jsonl (your desk of pending work). " <>
          "Persists across heartbeats; read back when you next wake on a timer.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The pending item to add. One line, free-form text."
          }
        },
        "required" => ["text"]
      }
    }
  end

  def call(%{mud_ctx: ctx}, %{"text" => text})
      when is_map(ctx) and is_binary(text) and text != "" do
    case Agenda.append(%{"text" => text}, ctx) do
      :ok -> {:ok, "agenda updated"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx),
    do: {:error, "update_agenda requires a non-empty 'text' field"}

  # No MUD ctx — not in the world, no home agenda. Fail closed.
  def call(_state, _input), do: {:error, "You are not in the world."}
end
