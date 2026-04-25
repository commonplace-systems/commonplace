defmodule Commonplace.Chat.Actions do
  @moduledoc """
  Action handlers for chat-room views (CX-487i / V1+V2).

  Each public function here is the implementation of a chat-room action
  declared in `_view.xml` and dispatched through
  `Commonplace.ViewActionDispatch`. The dispatcher's chat clauses are
  thin — they unpack the context and delegate here.

  ## Why this module exists

  Per chat-room.md (commit a5f3f5e on commonplace-plan/main), the chat
  doc avoids a per-view declarative actions surface (that's CX-y3q's
  story). Instead, ViewActionDispatch grows new `do_dispatch` clauses
  per chat action; each clause delegates to a focused function here.
  Keeps the dispatcher pattern-match shallow and the action logic in a
  module testable on its own.

  V1+V2 ship `post_message/3`. V3 will add `edit_message/3` and
  `delete_message/3`. V4 (followup) adds `react/3`.

  ## Signing

  Until CX-88mw lands per-agent key minting, `:signing_context` in opts
  is the substrate seam (CX-o3r7) — when present, the resulting commit
  is signed with that context's key. When absent, falls back to the
  global SecretStore or unsigned, matching the existing CommitStore
  default-signing behavior.
  """

  alias Commonplace.Chat.Messages
  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  @doc """
  Post a new message to the `_messages` doc identified by
  `messages_uuid`. Required opts: `:room`, `:signer_id`,
  `:author_path`. Optional: `:reply_to`, `:signing_context`, `:store`
  (defaults to `CommitStoreClient`).

  Returns `{:ok, %{message_id: id, ts: iso8601_string}}` on success.
  Returns `{:error, :not_found}` if the messages doc is unknown.
  Returns `{:error, reason_string}` on missing required opts.
  """
  def post_message(messages_uuid, text, opts)
      when is_binary(messages_uuid) and is_binary(text) and is_list(opts) do
    with :ok <- require_opt(opts, :room),
         :ok <- require_opt(opts, :signer_id),
         :ok <- require_opt(opts, :author_path) do
      store = Keyword.get(opts, :store, CommitStoreClient)
      signing_context = Keyword.get(opts, :signing_context)

      case load_messages_doc(store, messages_uuid) do
        {:ok, doc} ->
          message_id = UUID.uuid4()
          ts = DateTime.utc_now() |> DateTime.to_iso8601()

          entry =
            %{
              "id" => message_id,
              "ts" => ts,
              "author_signer_id" => Keyword.fetch!(opts, :signer_id),
              "author_path" => Keyword.fetch!(opts, :author_path),
              "text" => text
            }
            |> maybe_put("reply_to", Keyword.get(opts, :reply_to))

          doc = Messages.append(doc, entry)
          update = Yelixer.Encoding.encode_update(doc)

          commit_opts =
            if signing_context, do: [signing_context: signing_context], else: []

          CommitStoreClient.create_chained_commit(
            store,
            messages_uuid,
            update,
            %{},
            commit_opts
          )

          broadcast_post(Keyword.fetch!(opts, :room), entry)

          {:ok, %{message_id: message_id, ts: ts}}

        :none ->
          {:error, :not_found}
      end
    end
  end

  # --- Private ---

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, "missing required opt: #{inspect(key)}"}
      "" -> {:error, "missing required opt: #{inspect(key)}"}
      _ -> :ok
    end
  end

  defp load_messages_doc(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> {:ok, doc}
      :none -> :none
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp broadcast_post(room, entry) do
    payload = %{
      "message_id" => entry["id"],
      "author_signer_id" => entry["author_signer_id"],
      "author_path" => entry["author_path"],
      "ts" => entry["ts"]
    }

    msg = Magenta.message("post", "chat", payload)
    Magenta.send("chat:#{room}:events", msg)
    :ok
  end
end
