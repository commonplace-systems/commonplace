defmodule Commonplace.Dataflow.Magenta do
  @moduledoc """
  Ephemeral magenta messaging on path-based topics.

  Magenta messages are fire-and-forget broadcasts with a standard
  envelope: {type, source, payload, timestamp}. Used for process
  lifecycle commands, inter-process communication, and notifications.
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
