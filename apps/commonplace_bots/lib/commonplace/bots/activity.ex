defmodule Commonplace.Bots.Activity do
  @moduledoc """
  The room-level `__bot_activity` substrate doc — an append-only
  YArray of JSON entries giving the *room's* view of bot activity.
  It has two producers, both routed through the dispatcher:

    * the trigger decisions the dispatcher *acts on* — `fired`
      (worker spawned) and `suppressed` (rate-limited); and
    * the outcome of each worker it spawned — `completed`,
      `cap_hit`, `error` (the CX-gptu worker-outcome fan-out).

  A `:skip` trigger decision is deliberately NOT recorded here — it
  emits telemetry only, never an activity entry — so the log stays
  scannable: every entry is a real wake or a wake's result. (For a
  bot's own private cross-room trail, see `__red_log` in
  `Commonplace.Bots.Worker`; this doc is the per-room counterpart.)

  Same shape as `Chat.Messages` (`_messages`): a top-level
  `ContentType.create(doc, :array, "__bot_activity")` array
  with JSON-encoded entries. The double-underscore prefix is
  the codebase's "system doc" convention; the `.usr` / `.bot` /
  `.exe` honorifics don't apply (this is a doc, not a presence
  entity).

  ## Entry schema

      %{
        "ts"           => "<iso8601>",
        "room"         => "<room-name>",
        "bot"          => "<stripped-display-name>" | nil,
        "decision"     => "fired" | "suppressed" | "completed" | "cap_hit" | "error",
        "reason"       => "<atom-as-string>",
        "message_id"   => "<chat msg id>" | nil
      }

    * `decision="fired"` — trigger matched, worker spawned.
    * `decision="suppressed"` — trigger matched but rate-limit
      blocked. `reason` ∈ {:per_room_burst, :per_bot_cooldown,
      :room_concurrency, :global_concurrency}.
    * `decision="completed"` — worker finished with :end_turn.
    * `decision="cap_hit"` — worker terminated on a cap; `reason`
      names which.
    * `decision="error"` — worker terminated with `:error`.

  ## Lifecycle

  The dispatcher ensures the `__bot_activity` doc exists for a
  room when `subscribe_room/3` is called (lazy mint, idempotent).
  The doc uuid is captured into the dispatcher's room map so
  appends don't need a fresh lookup each time.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Types.Array

  @doc_name "__bot_activity"
  @content_type "content"

  @doc """
  Ensure a `__bot_activity` doc exists under `room_dir_uuid`.
  Returns the doc uuid. Idempotent — if the entry already
  exists, returns its node_id; otherwise mints a fresh array
  doc and adds it.
  """
  @spec ensure_doc(String.t(), module() | atom()) :: {:ok, String.t()} | {:error, term()}
  def ensure_doc(room_dir_uuid, store \\ CommitStoreClient) do
    case DocBuilder.reconstruct_snapshot(store, room_dir_uuid) do
      {:ok, dir_doc} ->
        case Schema.get_entry(dir_doc, @doc_name) do
          {:ok, entry} ->
            {:ok, entry.node_id}

          :error ->
            mint_and_link(room_dir_uuid, dir_doc, store)
        end

      _ ->
        {:error, :room_dir_unreadable}
    end
  end

  defp mint_and_link(room_dir_uuid, dir_doc, store) do
    activity_uuid = UUID.uuid4()
    activity_doc = Yelixer.Doc.new()
    activity_doc = ContentType.create(activity_doc, :array, @doc_name)
    update = Yelixer.Encoding.encode_update(activity_doc)
    CommitStore.create_commit(real_store(store), activity_uuid, update, nil)

    new_dir_doc = Schema.add_file(dir_doc, @doc_name, activity_uuid)
    dir_update = Yelixer.Encoding.encode_update(new_dir_doc)
    CommitStore.create_chained_commit(real_store(store), room_dir_uuid, dir_update)

    {:ok, activity_uuid}
  end

  @doc """
  Append an entry to the `__bot_activity` doc.

  `entry` is a partial map; `ts` is stamped here if missing.
  Returns `:ok` (best-effort) or `{:error, reason}`.
  """
  @spec append(String.t(), map(), module() | atom()) :: :ok | {:error, term()}
  def append(activity_uuid, entry, store \\ CommitStoreClient) do
    entry =
      Map.put_new_lazy(entry, "ts", fn ->
        DateTime.utc_now() |> DateTime.to_iso8601()
      end)

    with {:ok, doc} <- DocBuilder.reconstruct_snapshot(store, activity_uuid),
         doc <- Array.push(doc, @content_type, [Jason.encode!(entry)]) do
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(real_store(store), activity_uuid, update)
      :ok
    else
      :none -> {:error, :missing}
      err -> {:error, err}
    end
  end

  @doc """
  Read all entries from an activity doc, oldest-first. Used by
  tests + future replay-from-log rate-limit rebuild.
  """
  @spec list(String.t(), module() | atom()) :: [map()]
  def list(activity_uuid, store \\ CommitStoreClient) do
    case DocBuilder.reconstruct_snapshot(store, activity_uuid) do
      {:ok, doc} ->
        doc
        |> Array.to_list(@content_type)
        |> Enum.map(&Jason.decode!/1)

      _ ->
        []
    end
  end

  defp real_store(CommitStoreClient), do: CommitStore
  defp real_store(other), do: other
end
