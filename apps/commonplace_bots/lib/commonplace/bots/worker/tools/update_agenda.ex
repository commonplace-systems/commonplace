defmodule Commonplace.Bots.Worker.Tools.UpdateAgenda do
  @moduledoc """
  `update_agenda` tool (Camillo C3b, semantics fixed C5b) — REWRITE the bot's
  agenda (its "desk"), bot-signed.

  ## Finding (C5b): this used to append, and that was the bug's other half

  The tool's docstring and description always framed this as "your desk of
  pending work" — a thing you tidy, not a log you grow. But the C3b
  implementation called `Commonplace.Bots.Agenda.append/2`, which only ever
  CONCATENATES. Every heartbeat that wrote back left the previous item(s)
  sitting there too, forever — there is no "done" mechanism anywhere in the
  agenda schema to retire an old entry. That's the direct cause of CX-93rv's
  live symptom (a 6-entry agenda full of duplicates): not just the missing
  idempotence guard on a re-armed provision seed, but the tool ITSELF having
  no way to shrink the desk on an ordinary turn. `update_agenda` now calls
  `Commonplace.Bots.Agenda.replace/2` — REPLACING the entire `"entries"` list
  with `[{"text" => text}]` (stamped `"ts"` if omitted). A heartbeat turn that
  wants to keep more than one pending item live must say so explicitly in
  `text`; a bare call now leaves EXACTLY what was said as the whole desk,
  never a growing tail of everything ever queued.

  `Commonplace.Bots.Agenda.append/2` still exists (and gained CX-93rv's
  entry-keyed dedupe) for the one caller that genuinely wants a growing log:
  provision-time seeding.

  Like every C3a tool this is allowlisted: a bot only gets it if its
  grantor-signed charter grants `"update_agenda"`. The write lands in the
  bot's `home/agenda/` note-meta (C3d) via `Agenda.replace/2` — zoned,
  bot-signed, home-anchored, zone-preserving (`World.merge_meta`, never a
  struct round-trip — CX-cl65), resolved from `state.mud_ctx`. A bot with no
  `mud_ctx` (unprovisioned) refuses gracefully.
  """

  alias Commonplace.Bots.Agenda

  def name, do: "update_agenda"

  def definition do
    %{
      "name" => "update_agenda",
      "description" =>
        "Rewrite your agenda (your desk of pending work) — REPLACES whatever was " <>
          "there, it does not add a line to a growing log. Persists across " <>
          "heartbeats; read back when you next wake on a timer.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" =>
              "The pending item now on your desk. Replaces everything previously there."
          }
        },
        "required" => ["text"]
      }
    }
  end

  def call(%{mud_ctx: ctx}, %{"text" => text})
      when is_map(ctx) and is_binary(text) and text != "" do
    case Agenda.replace([%{"text" => text}], ctx) do
      :ok -> {:ok, "agenda updated"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx),
    do: {:error, "update_agenda requires a non-empty 'text' field"}

  # No MUD ctx — not in the world, no home agenda. Fail closed.
  def call(_state, _input), do: {:error, "You are not in the world."}
end
