defmodule Commonplace.Bots.Worker.Tools.Move do
  @moduledoc """
  `move` tool (Camillo C3c) — walk the bot's `.usr` presence one exit.

  The DEMO's visible motion: a heartbeat turn calls this, the bot's `.usr`
  presence physically relocates in the world tree (observable on :5199), and the
  turn is visibly ALIVE with no chat involved.

  ## Pins upheld

    * **(b) one motion path.** The move bottoms out on
      `Commonplace.MUD.World.move_presence/5` — the CX-avzp gated presence-move
      chokepoint every player's `go` uses. No parallel move path: `presence.move`
      stays the only motion verb.
    * **(a) position read fresh.** The source room and presence doc uuid come
      from `state.mud_ctx`, which `Commonplace.Bots.Worker.Loop.dispatch_tool/2`
      re-reads from the live `.usr` presence immediately before EVERY tool
      dispatch (CX-mpk0, cp-plan #8933/#8934 — generalized from the original
      once-per-turn resolve) — never a cached room, whether the staleness
      would have come from a prior turn or an earlier tool call THIS turn.
    * **(c) creds from the ctx only.** `signing_context` / `cert_cids` /
      `signer_id` / the `viewer` are all taken from the resolved `mud_ctx`, never
      from the tool input (which carries only a direction).

  A missing `mud_ctx` (unprovisioned bot) or an absent exit refuses with a
  SANITIZED message that never enumerates internals (thin-handle).
  """

  alias Commonplace.MUD.{Schemas.Room, World}

  def name, do: "move"

  def definition do
    %{
      "name" => "move",
      "description" =>
        "Walk one step in a compass direction (e.g. north, south, east, west). " <>
          "Moves your presence in the world to the adjacent room, if an exit leads that way.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "direction" => %{
            "type" => "string",
            "description" => "The direction to walk, e.g. \"north\"."
          }
        },
        "required" => ["direction"]
      }
    }
  end

  def call(%{mud_ctx: ctx}, %{"direction" => direction})
      when is_map(ctx) and is_binary(direction) and direction != "" do
    dir = String.trim(direction)
    ctx.current_room_uuid |> World.get_room(ctx.store) |> step(dir, ctx)
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx),
    do: {:error, "Go where? Name a direction."}

  # No MUD ctx — the bot isn't standing in the world (unprovisioned / no
  # presence). Sanitized refusal, no internals.
  def call(_state, _input), do: {:error, "You are not in the world."}

  defp step({:ok, %Room{exits: exits}}, dir, ctx) do
    case Map.get(exits, dir) do
      dest when is_binary(dest) -> walk(dir, dest, ctx)
      _ -> {:error, "You can't go that way."}
    end
  end

  defp step(_room_err, _dir, _ctx), do: {:error, "You can't go that way."}

  # THE single motion path: the CX-avzp gated presence-move chokepoint (pin b).
  # First arg is the PRESENCE DOC uuid (the entry `move_presence` relocates —
  # `Move.check_still_there` matches it against the room entry's node_id), NOT
  # the identity uuid. All creds ride from the ctx (pin c).
  defp walk(dir, dest, ctx) do
    case World.move_presence(
           ctx.presence_uuid,
           ctx.presence_filename,
           ctx.current_room_uuid,
           dest,
           store: ctx.store,
           signing_context: ctx.signing_context,
           cert_cids: ctx.cert_cids,
           signer_id: ctx.signer_id,
           viewer: ctx.signing_context.identity_uuid
         ) do
      :ok -> {:ok, "You walk #{dir}. #{dest_name(dest, ctx)}"}
      {:error, _reason} -> {:error, "You can't go that way."}
    end
  end

  defp dest_name(dest, ctx) do
    case World.get_room(dest, ctx.store) do
      {:ok, %Room{name: name}} when is_binary(name) and name != "" -> "You are now in #{name}."
      _ -> "You arrive somewhere new."
    end
  end
end
