defmodule Commonplace.Bots.Worker.Tools.ReadChat do
  @moduledoc """
  `read_chat` tool — return the most recent N chat messages as
  pre-rendered `"<author>: <text>"` lines.

  Cheap on tokens compared to dumping raw YArray entries. `msg_id`
  and `ts` ride as metadata fields on each line's wrapping JSON.

  Tombstoned and edited messages are resolved via the same
  `Chat.Messages.materialize/1` path the chat view uses.

  Optional `before` arg = a message_id; if supplied, the result
  is the N messages whose array-position precedes that id (used
  for paging back through history).

  ## No chat thread here (CX-0xt0)

  `:messages_uuid` in `state.opts` is threaded on the CHAT path
  (`Commonplace.Bots.Dispatcher.invoke_worker_chat/4`) and, since CX-0xt0,
  on the autonomous heartbeat path too WHEN the bot has a subscribed
  `chat_rooms` entry — but a bot with no registered/subscribed room at all
  genuinely has no chat thread to read. This used to `Keyword.fetch!/2`
  and CRASH THE WHOLE WORKER TASK on that absence (a real live incident:
  a heartbeat-woken turn called `read_chat`, hit the missing key, and the
  Task died mid-turn — no transcript, no reply). A tool must NEVER crash
  the worker on missing context; `dispatch_tool/2`'s whole contract is
  that a tool error becomes an `is_error` `tool_result`, not an exception.
  Missing `:messages_uuid` now returns the SAME kind of honest,
  in-fiction refusal every other MUD tool uses for "there's nothing here"
  — `{:error, "(you have no chat thread here)"}` — never a raise.
  """

  alias Commonplace.Chat.Messages
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  @default_limit 20
  @max_limit 100

  def name, do: "read_chat"

  def definition do
    %{
      "name" => "read_chat",
      "description" =>
        "Read recent chat messages from the room. Returns a JSON array of {msg_id, ts, author, text}.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max messages to return (default 20, capped at 100).",
            "minimum" => 1,
            "maximum" => @max_limit
          },
          "before" => %{
            "type" => "string",
            "description" =>
              "Optional message_id; return only messages preceding it in array order."
          }
        }
      }
    }
  end

  def call(state, input) do
    case Keyword.get(state.opts, :messages_uuid) do
      nil ->
        {:error, "(you have no chat thread here)"}

      messages_uuid ->
        limit = input |> Map.get("limit", @default_limit) |> clamp()
        before = Map.get(input, "before")
        store = Keyword.get(state.opts, :store, CommitStoreClient)

        with {:ok, doc} <- DocBuilder.reconstruct_snapshot(store, messages_uuid) do
          entries = Messages.materialize(doc)

          sliced =
            entries
            |> filter_before(before)
            |> Enum.take(-limit)
            |> Enum.map(&render/1)

          {:ok, Jason.encode!(sliced)}
        else
          _ -> {:error, "messages doc unreadable"}
        end
    end
  end

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp(_), do: @default_limit

  defp filter_before(entries, nil), do: entries

  defp filter_before(entries, id) do
    case Enum.find_index(entries, fn e -> Map.get(e, "id") == id end) do
      nil -> entries
      idx -> Enum.take(entries, idx)
    end
  end

  defp render(entry) do
    %{
      "msg_id" => Map.get(entry, "id"),
      "ts" => Map.get(entry, "ts"),
      "author" => Map.get(entry, "author_path"),
      "text" => Map.get(entry, "text", "")
    }
  end
end
