defmodule Commonplace.MCP.Tools.TailRed do
  @moduledoc """
  MCP tool: read persisted events from a red log document.

  Red logs are the persistent, gold-attested audit chain for a given
  document UUID. This tool loads one and returns its events, optionally
  skipping the first N (so an agent can poll for "events since last
  time" by tracking the count).
  """

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.MCP.Tools.Response
  alias Commonplace.Store.CommitStoreClient

  def descriptor do
    %{
      "name" => "tail_red",
      "description" =>
        "Read events from a red log. Red is the persistent, append-only, gold-attested audit channel in commonplace. Pass the UUID of the red log document and optionally a 'since' integer to skip events you've already seen. Returns the event list and the new total count so you can poll incrementally.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "uuid" => %{
            "type" => "string",
            "description" => "UUID of the red log document to tail."
          },
          "since" => %{
            "type" => "integer",
            "description" =>
              "Optional: skip the first N events (useful for incremental polling). Defaults to 0."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Optional: maximum number of events to return. Defaults to 100."
          }
        },
        "required" => ["uuid"]
      }
    }
  end

  def run(%{"uuid" => uuid} = args) when is_binary(uuid) do
    since = Map.get(args, "since", 0)
    limit = Map.get(args, "limit", 100)

    log = RedLog.load(uuid, CommitStoreClient)
    all_events = RedLog.read(log)
    total = length(all_events)

    events =
      all_events
      |> Enum.drop(since)
      |> Enum.take(limit)

    {:ok,
     Response.text(
       "Read #{length(events)} event(s) from #{uuid} (total #{total})",
       %{
         "uuid" => uuid,
         "total" => total,
         "since" => since,
         "returned" => length(events),
         "events" => events
       }
     )}
  end

  def run(_args), do: {:error, :invalid_params, "uuid (string) is required"}
end
