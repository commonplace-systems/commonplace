defmodule Commonplace.MUD.Topics do
  @moduledoc """
  Phoenix PubSub topic keys for the MUD.

  Rooms use red event log keyed by room doc UUID; players use red event
  log keyed by player doc UUID; player input arrives on a magenta path
  keyed by player UUID.
  """

  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  def room_topic(room_uuid), do: "red:#{room_uuid}"
  def player_tell_topic(player_uuid), do: "red:#{player_uuid}"

  def subscribe_room(room_uuid), do: CPPubSub.subscribe_red(room_uuid)
  def unsubscribe_room(room_uuid), do: Phoenix.PubSub.unsubscribe(Commonplace.PubSub, room_topic(room_uuid))
  def broadcast_room(room_uuid, msg), do: CPPubSub.broadcast_red(room_uuid, msg)

  def subscribe_player_tell(player_uuid), do: CPPubSub.subscribe_red(player_uuid)
  def broadcast_player_tell(player_uuid, msg), do: CPPubSub.broadcast_red(player_uuid, msg)

  def player_input_path(player_uuid), do: "mud/input/" <> player_uuid
  def subscribe_player_input(player_uuid), do: CPPubSub.subscribe_magenta(player_input_path(player_uuid))
  def broadcast_player_input(player_uuid, line), do: CPPubSub.broadcast_magenta(player_input_path(player_uuid), {:input, line})
end
