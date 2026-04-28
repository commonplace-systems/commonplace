defmodule Commonplace.MCP.Tools.MudSend do
  @moduledoc """
  MCP tool: send a line of input to the MUD as bot `name`. Lazily
  spawns a buffered PlayerSession on first call; subsequent calls
  reuse it (subscriptions persist).

  Returns the events the bot's session emitted while processing the
  command (room renders, tells, broadcasts heard, etc).
  """

  alias Commonplace.MCP.Tools.Response
  alias Commonplace.MUD.Bot

  def descriptor do
    %{
      "name" => "mud_send",
      "description" =>
        "Send a single line of input to the MUD as the named bot. Spawns a long-lived player session for the bot on first call (subsequent calls reuse it). Returns events the session emitted while processing — room renders, broadcasts heard from other players, tells, verb errors, etc. Use `mud_read` between commands to poll for ambient events without sending input.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" =>
              "Bot identity. Used as the .usr presence file name in the world tree. Lowercase letters / digits / underscore / hyphen."
          },
          "line" => %{
            "type" => "string",
            "description" =>
              "A single MUD command line — same as a human player would type at the CLI. Examples: `look`, `north`, `say hello`, `take cloak`, `@verb cloak:bow`, `inventory`."
          }
        },
        "required" => ["name", "line"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, _context \\ %{})

  def run(%{"name" => name, "line" => line}, _ctx)
      when is_binary(name) and is_binary(line) do
    case Bot.send_input(name, line) do
      {:ok, events} ->
        events_text = format(events)
        {:ok, Response.text(events_text, %{"events" => events})}

      {:error, reason} ->
        {:error, :invalid_params, "MUD send failed: #{inspect(reason)}"}
    end
  end

  def run(_args, _ctx),
    do: {:error, :invalid_params, "Missing or non-string `name` / `line` arguments."}

  defp format([]), do: "(no events)"
  defp format(events), do: Enum.join(events, "\n")
end
