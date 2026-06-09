defmodule Commonplace.Dataflow.Magenta do
  @moduledoc """
  Structured ephemeral messaging on the **magenta** channel.

  Magenta is the fire-and-forget color (see `Commonplace.Dataflow.Channel`
  for where it sits in the taxonomy): transient, unpersisted broadcasts
  used for process-lifecycle commands, inter-process notifications, and
  the like. If nobody is subscribed when a message is sent, it is simply
  gone — there is no durability and no delivery guarantee. This module is
  the *structured* layer over that channel: a message struct plus a
  routing scheme.

  ## Paths and topics

  Messages are addressed by a **path** — a slash-delimited logical
  address such as `commands/{node}/merge`, *not* a document uuid and not
  necessarily a filesystem path. It maps to the Phoenix PubSub topic
  `magenta:{path}`. A subscriber to that exact path receives messages as
  `{:magenta, path, %Magenta{}}` — the producer sends this tuple directly
  rather than through the generic `Commonplace.Dataflow.PubSub` wrapper,
  so match *this* shape in `handle_info`, not a `{topic, message}`
  envelope. The message struct itself carries the fields
  `{type, source, payload, timestamp}`.

  ## Verb-sentinel dispatch (the wildcard workaround)

  Phoenix PubSub has no wildcard subscription, so a singleton handler
  that must see *every* `commands/{anything}/merge` command cannot
  subscribe to `commands/*/merge`. To solve this without a per-path
  subscriber tree, every `send/2` *also* broadcasts to a **verb sentinel**
  topic derived from the path's final segment: a send to
  `commands/foo/merge` additionally hits `magenta:__verbs:merge`. A
  handler calls `subscribe_to_verb("merge")` and thereby receives every
  merge command regardless of the path prefix. This is the β-topology
  sentinel dispatch used by the merge command handler (CX-8qzi); the
  extra broadcast costs nothing when nobody is subscribed to the
  sentinel.
  """

  defstruct [:type, :source, :payload, :timestamp]

  @type t :: %__MODULE__{
          type: String.t(),
          source: String.t(),
          payload: map(),
          timestamp: DateTime.t()
        }

  @doc "Create a new magenta message."
  def message(type, source, payload \\ %{}) do
    %__MODULE__{
      type: type,
      source: source,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Send a magenta message on a path-based topic.

  Also fans out to the verb-sentinel topic derived from the final
  path segment (e.g. `commands/foo/merge` → sentinel `merge`). This
  lets a singleton subscriber handle all commands for a given verb
  without needing wildcard subscription (which Phoenix.PubSub lacks)
  or a per-path subscriber tree. Non-subscribers on the sentinel
  incur no cost — broadcast is a no-op when nobody's listening.
  """
  def send(path, %__MODULE__{} = msg) do
    topic = "magenta:#{path}"
    Phoenix.PubSub.broadcast(Commonplace.PubSub, topic, {:magenta, path, msg})

    case verb_sentinel(path) do
      nil ->
        :ok

      sentinel ->
        Phoenix.PubSub.broadcast(Commonplace.PubSub, sentinel, {:magenta, path, msg})
    end
  end

  @doc "Subscribe to magenta messages on a path-based topic."
  def subscribe(path) do
    Phoenix.PubSub.subscribe(Commonplace.PubSub, "magenta:#{path}")
  end

  @doc """
  Subscribe to all magenta messages whose topic's final path segment
  equals `verb`. Implements the β-topology sentinel dispatch used by
  the merge command handler (CX-8qzi): one subscriber sees every
  `commands/{path}/merge` command regardless of `{path}`.
  """
  def subscribe_to_verb(verb) when is_binary(verb) and verb != "" do
    Phoenix.PubSub.subscribe(Commonplace.PubSub, "magenta:__verbs:#{verb}")
  end

  defp verb_sentinel(path) do
    case path |> String.split("/") |> List.last() do
      nil -> nil
      "" -> nil
      verb -> "magenta:__verbs:#{verb}"
    end
  end

  @doc "Serialize a message to JSON."
  def to_json(%__MODULE__{} = msg) do
    %{
      "type" => msg.type,
      "source" => msg.source,
      "payload" => msg.payload,
      "timestamp" => DateTime.to_iso8601(msg.timestamp)
    }
    |> Jason.encode!()
  end

  @doc "Serialize a message to a map (for storage in YArray)."
  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => msg.type,
      "source" => msg.source,
      "payload" => msg.payload,
      "timestamp" => DateTime.to_iso8601(msg.timestamp)
    }
  end
end
