defmodule Commonplace.MCP.Tools.LoomRead do
  @moduledoc """
  MCP tool: read messages from the `#loom` chat room (CX-6sf2.1 A1).

  Returns the room's materialized message view (`Commonplace.Chat.Messages.materialize/1`
  — edit/tombstone chains already resolved) filtered to entries AFTER
  a caller-supplied cursor, plus a new cursor for the next page.

  ## Cursor definition

  The cursor is the `id` of the last message the caller has seen — NOT
  an array index and NOT the `ts` field. Two things rule those out:

    * message `id`s are random UUIDv4s (`Commonplace.Chat.Actions`),
      not orderable by value — so the cursor can't be "return ids
      greater than X".
    * `ts` is explicitly documented (`Messages` moduledoc) as a
      wall-clock hint only, and an *edit* to a message overwrites its
      materialized `ts` with the edit's timestamp (see `Materialize`'s
      `:latest_replaces` semantics) — so `ts` isn't even stable across
      reads of the SAME message, let alone monotonic across posts.

  Instead, "since cursor" is resolved positionally: the materialized
  list is emitted in original-array-position order (an append-only
  invariant `Commonplace.Materialize` documents directly), so we find
  the cursor id's index in that list and return everything after it.
  This is robust regardless of id randomness or ts collisions/edits,
  and the new cursor returned is simply the last entry's id — an
  opaque token from the agent's point of view.

  A `since` that doesn't resolve to any known message id (stale cursor,
  e.g. after a room reset) falls back to returning the full
  materialized list rather than erroring.

  No cursor (`since` omitted or nil) returns the most recent
  `@default_tail` messages (cap, so a long-lived room doesn't dump its
  whole history) plus a cursor positioned at the end of that page.
  """

  alias Commonplace.Chat.{LoomRoom, Messages}
  alias Commonplace.MCP.Tools.Response
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Workspace

  @default_tail 50

  def descriptor do
    %{
      "name" => "loom_read",
      "description" =>
        "Read messages posted to the #loom chat room since a cursor (from a prior loom_read/loom_send). Omit `since` to get the recent tail. Returns `messages` (materialized — edits/deletes already resolved) and a `cursor` to pass next time.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "since" => %{
            "type" => "string",
            "description" =>
              "Cursor from a previous loom_read/loom_send call (a message id). Returns only messages after it. Omit for the recent tail."
          }
        },
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(args, _context) when is_map(args) do
    since = Map.get(args, "since")

    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, room} <- LoomRoom.ensure(root_uuid),
         {:ok, doc} <- DocBuilder.reconstruct_snapshot(CommitStoreClient, room.messages_uuid) do
      materialized = Messages.materialize(doc)
      {entries, cursor} = page(materialized, since)

      {:ok, Response.text(summary(entries), %{"messages" => entries, "cursor" => cursor})}
    else
      :none ->
        {:ok, Response.text("(no messages)", %{"messages" => [], "cursor" => since})}

      {:error, reason} ->
        {:error, :invalid_params, "loom_read failed: #{inspect(reason)}"}
    end
  end

  defp page(materialized, nil) do
    tail = Enum.take(materialized, -@default_tail)
    {tail, last_id(tail, nil)}
  end

  defp page(materialized, since) when is_binary(since) do
    case Enum.find_index(materialized, fn m -> m["id"] == since end) do
      nil ->
        {materialized, last_id(materialized, since)}

      idx ->
        rest = Enum.drop(materialized, idx + 1)
        {rest, last_id(rest, since)}
    end
  end

  defp last_id([], fallback), do: fallback
  defp last_id(list, _fallback), do: List.last(list)["id"]

  defp summary([]), do: "(no new messages)"
  defp summary(entries), do: "#{length(entries)} message(s)."
end
