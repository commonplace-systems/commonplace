defmodule Commonplace.Dataflow.PubSub do
  @moduledoc """
  Phoenix PubSub wrapper implementing color channel topic conventions.

  Topics:
    blue:{uuid}      - CRDT state updates
    cyan:{uuid}      - directed writes
    red:{uuid}       - persistent event log entries
    magenta:{path}   - ephemeral commands
    green:{uuid}     - lock acquisition/release
  """

  def subscribe_blue(uuid), do: subscribe("blue:#{uuid}")
  def subscribe_cyan(uuid), do: subscribe("cyan:#{uuid}")
  def subscribe_red(uuid), do: subscribe("red:#{uuid}")
  def subscribe_magenta(path), do: subscribe("magenta:#{path}")
  def subscribe_green(uuid), do: subscribe("green:#{uuid}")

  def unsubscribe_blue(uuid), do: unsubscribe("blue:#{uuid}")

  def broadcast_blue(uuid, message), do: broadcast("blue:#{uuid}", message)
  def broadcast_cyan(uuid, message), do: broadcast("cyan:#{uuid}", message)
  def broadcast_red(uuid, message), do: broadcast("red:#{uuid}", message)
  def broadcast_magenta(path, message), do: broadcast("magenta:#{path}", message)
  def broadcast_green(uuid, message), do: broadcast("green:#{uuid}", message)

  defp subscribe(topic) do
    Phoenix.PubSub.subscribe(Commonplace.PubSub, topic)
  end

  defp unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(Commonplace.PubSub, topic)
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(Commonplace.PubSub, topic, {topic, message})
  end
end
