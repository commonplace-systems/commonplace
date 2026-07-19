defmodule Commonplace.Bots.Worker.Tools.Look do
  @moduledoc """
  `look` tool (Camillo C3c) — the bot's view of the room it stands in.

  Renders the room the bot's `.usr` presence currently occupies as text: name,
  description, exits, visible objects, and other occupants. The room comes from
  `state.mud_ctx.current_room_uuid`, which the Worker re-resolved THIS turn from
  the live presence (pin a) — so a look always reflects where the bot actually
  is, even after an external move.

  Reads through `Commonplace.MUD.World.room_snapshot/4`, the SAME read-scoped
  snapshot the player pane uses; the `viewer` is taken from the resolved ctx
  (pin c) so a capability-gated room is judged against the bot's own identity.
  A missing `mud_ctx` refuses gracefully (thin-handle).
  """

  alias Commonplace.MUD.World

  def name, do: "look"

  def definition do
    %{
      "name" => "look",
      "description" =>
        "Look at the room you are standing in: its name, description, exits, " <>
          "objects, and who else is here.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    }
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx) do
    case World.room_snapshot(ctx.current_room_uuid, ctx.presence_filename, ctx.store,
           viewer: ctx.signing_context.identity_uuid
         ) do
      {:ok, snapshot} -> {:ok, render(snapshot)}
      {:error, _reason} -> {:error, "You can't see anything here."}
    end
  end

  # No MUD ctx — the bot isn't standing in the world. Sanitized refusal.
  def call(_state, _input), do: {:error, "You are not in the world."}

  defp render(%{name: name, desc: desc, exits: exits, contents: contents, occupants: occupants}) do
    [
      name || "(unnamed room)",
      desc || "",
      render_line("Exits", Enum.map(exits, fn {dir, _to} -> dir end)),
      render_line("Here", contents),
      render_line("Also here", occupants)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp render_line(_label, []), do: ""
  defp render_line(label, items), do: "#{label}: #{Enum.join(items, ", ")}"
end
