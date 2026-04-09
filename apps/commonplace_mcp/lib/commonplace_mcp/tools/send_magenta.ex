defmodule Commonplace.MCP.Tools.SendMagenta do
  @moduledoc """
  MCP tool: broadcast a magenta message on a named topic.

  Thin pass-through to `Commonplace.Dataflow.Magenta.send/2`. Anything
  subscribed to that topic (other agents, red-log onramps, LiveView
  dashboards) will receive it. Use this to send commands to other
  processes in the graph, respond to requests, or notify observers.
  """

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.MCP.Tools.Response

  def descriptor do
    %{
      "name" => "send_magenta",
      "description" =>
        "Broadcast a magenta message (ephemeral pub/sub command) on the given topic. Magenta is the fire-and-forget command channel — use it to send instructions, announce events, or reply to requests. The message is delivered to every subscriber on the topic, but is not persisted unless someone has an onramp to red for that topic.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" =>
              "Magenta topic path (e.g. '__commands', 'chat/room1', 'agent:claude')."
          },
          "type" => %{
            "type" => "string",
            "description" =>
              "Message type — namespaced string like 'chat.message', 'task.start', 'reply'."
          },
          "payload" => %{
            "type" => "object",
            "description" => "Arbitrary JSON payload with the message body. Defaults to {}."
          }
        },
        "required" => ["topic", "type"]
      }
    }
  end

  def run(%{"topic" => topic, "type" => type} = args)
      when is_binary(topic) and is_binary(type) do
    payload = Map.get(args, "payload", %{})
    source = Map.get(args, "source", "mcp")

    msg = Magenta.message(type, source, payload)
    Magenta.send(topic, msg)

    {:ok,
     Response.text(
       "Sent magenta '#{type}' on topic '#{topic}'",
       %{"topic" => topic, "type" => type, "timestamp" => DateTime.to_iso8601(msg.timestamp)}
     )}
  end

  def run(_args),
    do: {:error, :invalid_params, "topic (string) and type (string) are required"}
end
