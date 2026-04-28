defmodule Commonplace.MUD.Output do
  @moduledoc """
  Convenience wrappers for in-world verb authors. Verbs receive a `ctx`
  map and want to emit text — this module gives them one-arg helpers
  pulling the right UUID out of ctx so they don't have to remember
  which field is which.

      defmodule UserVerb do
        alias Commonplace.MUD.Output

        def run(ctx) do
          Output.tell(ctx, "You feel mysterious.")
          Output.broadcast(ctx, "\#{ctx.player_name} swirls dramatically.")
          :ok
        end
      end

  Under the hood these just forward to `Commonplace.MUD.World.tell/2`
  and `World.broadcast_room/2,3`. Use World directly if you need
  something the wrappers don't expose (e.g. broadcasting to a
  different room than the actor is in).
  """

  alias Commonplace.MUD.World

  @doc """
  Emit a private message to the actor only. Accepts a string (rendered
  as a custom event) or a map (passed through as a structured red
  event payload).
  """
  def tell(%{player_uuid: uuid}, msg), do: World.tell(uuid, msg)

  @doc """
  Broadcast a room-visible event. Accepts a string (custom event) or
  a structured map. By default the actor is excluded so they only see
  whatever you `tell/2` them — pass `except: false` to also send the
  broadcast to the actor (rare).
  """
  def broadcast(ctx, msg, opts \\ [])

  def broadcast(%{current_room_uuid: room, player_uuid: actor}, msg, opts) do
    except =
      case Keyword.get(opts, :except, :default) do
        :default -> [actor]
        false -> []
        list when is_list(list) -> list
      end

    World.broadcast_room(room, msg, except: except)
  end

  @doc """
  Send an event to a specific player UUID (e.g. for a whisper). Use
  `tell/2` for the actor; this is for everyone else.
  """
  def tell_player(uuid, msg) when is_binary(uuid), do: World.tell(uuid, msg)
end
