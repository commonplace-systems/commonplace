defmodule Commonplace.MCP.Tools.MudRead do
  @moduledoc """
  MCP tool: drain pending events for bot `name` without sending input.
  Use between `mud_send` calls to pick up ambient events (other
  players talking, tick verbs firing, etc).
  """

  alias Commonplace.MCP.Tools.Response
  alias Commonplace.MUD.Bot

  def descriptor do
    %{
      "name" => "mud_read",
      "description" =>
        "Drain pending events for the named MUD bot without sending input. Returns events that arrived since the last mud_send / mud_read call. Spawns the bot's session lazily if one doesn't exist (so the bot starts subscribing).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Bot identity (matches `mud_send`)."
          }
        },
        "required" => ["name"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, _context \\ %{})

  def run(%{"name" => name}, _ctx) when is_binary(name) do
    case Bot.read_events(name) do
      {:ok, events} ->
        events_text = format(events)
        {:ok, Response.text(events_text, %{"events" => events})}

      {:error, reason} ->
        {:error, :invalid_params, "MUD read failed: #{inspect(reason)}"}
    end
  end

  def run(_args, _ctx),
    do: {:error, :invalid_params, "Missing or non-string `name` argument."}

  defp format([]), do: "(no events)"
  defp format(events), do: Enum.join(events, "\n")
end
