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

  @doc "Send a magenta message on a path-based topic."
  def send(path, %__MODULE__{} = msg) do
    topic = "magenta:#{path}"
    Phoenix.PubSub.broadcast(Commonplace.PubSub, topic, {:magenta, path, msg})
  end

  @doc "Subscribe to magenta messages on a path-based topic."
  def subscribe(path) do
    Phoenix.PubSub.subscribe(Commonplace.PubSub, "magenta:#{path}")
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
