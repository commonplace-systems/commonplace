defmodule Commonplace.Dataflow.PubSub do
  @moduledoc """
  Thin convenience layer over Phoenix PubSub implementing the
  color-channel topic conventions.

  Each color flow uses the topic `color:{key}`. The colors and their
  *meanings* are defined in `Commonplace.Dataflow.Channel`; this module
  owns only the topic strings and the subscribe / broadcast / unsubscribe
  helpers:

    blue:{uuid}      - CRDT state updates
    cyan:{uuid}      - directed writes
    red:{uuid}       - persistent event-log entries
    magenta:{path}   - ephemeral commands
    green:{uuid}     - lock acquisition / release

  ## Message envelope

  The generic color broadcasters wrap the payload, so a subscriber's
  `handle_info` receives `{topic, message}` (e.g. `{"green:" <> uuid,
  msg}`) — subscribe with the matching `subscribe_*` helper and match
  that shape. Note that some hot-path producers publish their own message
  shape *directly* via `Phoenix.PubSub`, bypassing these wrappers —
  notably the `blue:` commit broadcast in `Commonplace.Store.CommitStore`
  (a bare `{:commit, uuid, commit_id, meta}`) — so match the shape the
  producer documents, not a uniform envelope.

  ## The sync channel

  `sync:{uuid}` is a separate, non-color channel for **cross-node commit
  replication**: `broadcast_commit/2` sends the *full* commit as
  `{:remote_commit, commit, source_node}` to peers in the BEAM cluster.
  This is distinct from `blue:`, which only notifies *local* subscribers
  that a commit happened; `sync:` carries the commit itself to *other
  nodes*. It is deliberately not one of the colors (absent from
  `Channel.colors/0`).
  """

  def subscribe_blue(uuid), do: subscribe("blue:#{uuid}")
  def subscribe_cyan(uuid), do: subscribe("cyan:#{uuid}")
  def subscribe_red(uuid), do: subscribe("red:#{uuid}")
  def subscribe_magenta(path), do: subscribe("magenta:#{path}")
  def subscribe_green(uuid), do: subscribe("green:#{uuid}")

  @doc "Subscribe to sync channel for distributed commit replication."
  def subscribe_sync(doc_uuid) do
    Phoenix.PubSub.subscribe(Commonplace.PubSub, "sync:#{doc_uuid}")
  end

  def unsubscribe_blue(uuid), do: unsubscribe("blue:#{uuid}")

  @doc "Unsubscribe from sync channel."
  def unsubscribe_sync(doc_uuid) do
    Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "sync:#{doc_uuid}")
  end

  def broadcast_blue(uuid, message), do: broadcast("blue:#{uuid}", message)
  def broadcast_cyan(uuid, message), do: broadcast("cyan:#{uuid}", message)
  def broadcast_red(uuid, message), do: broadcast("red:#{uuid}", message)
  def broadcast_magenta(path, message), do: broadcast("magenta:#{path}", message)
  def broadcast_green(uuid, message), do: broadcast("green:#{uuid}", message)

  @doc """
  Broadcast a full commit on the sync channel for distributed replication.
  Message format: {:remote_commit, commit, source_node}
  """
  def broadcast_commit(doc_uuid, commit) do
    Phoenix.PubSub.broadcast(
      Commonplace.PubSub,
      "sync:#{doc_uuid}",
      {:remote_commit, commit, Node.self()}
    )
  end

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
