defmodule Commonplace.Chat.Rooms do
  @moduledoc """
  CX-71o3 (C1 of CX-p2qp): chat room lifecycle.

  Per chat-room.md (commit bb83a1b on commonplace-plan/main), a chat
  room lives at `/chat/{name}/` with the canonical sub-doc layout:

      /chat/{name}/
        _view.xml          ← XHTML chrome + action declarations
        _messages          ← Y.Array of JSON-encoded message entries
        _reactions         ← top-level YMap with composite-key bool values
        _messages.log      ← red-channel onramp target

  This module owns ROOM lifecycle (create / lookup); per-message actions
  live in `Commonplace.Chat.Actions`; data-shape helpers in
  `Commonplace.Chat.Messages`. Three concerns kept separate.

  ## MVP scope guardrail

  `create/3` is intentionally minimal — directory + sub-docs + schema
  entries. Does NOT bake in:

  * Permissions / room-owner concept (CX-2zb white-channel followup)
  * Room metadata (description, topic) — chat keeps room identity to
    "name as path-safe string"
  * Default-member / auto-subscribe (presence is bubbled implicitly)

  If those need to land later they get their own beads.

  Lazy red-onramp start happens in `Chat.Actions.commit_entry` per R1
  (CX-9zpb); `create/3` does NOT eagerly start an onramp (would create
  two trigger paths to maintain).
  """

  alias Commonplace.Chat.{ChatViewBuilder, ChatViewCompute, Messages}
  alias Commonplace.CommandRouter
  alias Commonplace.Document.ContentType
  alias Commonplace.Materialize
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @chat_dir "chat"

  @doc """
  Create a chat room under `/chat/{room_name}/`. Returns the UUIDs of
  the room directory and all canonical sub-docs.

  Optional opts:
    * `:store` — CommitStore name (defaults to `CommitStoreClient`)

  Errors:
    * `{:error, :exists}` — room name is already taken under `/chat/`
    * `{:error, :invalid_name}` — name fails the path-safe check
      (empty, leading dot, contains slash)
  """
  def create(root_uuid, room_name, opts \\ [])
      when is_binary(root_uuid) and is_binary(room_name) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with :ok <- validate_name(room_name),
         {:ok, chat_dir_uuid} <- ensure_chat_dir(root_uuid, store),
         :ok <- ensure_not_exists(chat_dir_uuid, room_name, store) do
      {room_dir_uuid, sub_docs} = mint_room(room_name, store)

      # Add the room dir to the /chat schema.
      chat_schema = load_schema(chat_dir_uuid, store)
      chat_schema = Schema.add_directory(chat_schema, room_name, room_dir_uuid)
      update = Yelixer.Encoding.encode_update(chat_schema)
      CommitStoreClient.create_chained_commit(store, chat_dir_uuid, update)

      {:ok, Map.put(sub_docs, :room_dir_uuid, room_dir_uuid)}
    end
  end

  @doc """
  Resolve a room name to its sub-doc UUIDs by walking the workspace
  schema. Returns `{:error, :not_found}` if the room (or the `/chat`
  directory itself) doesn't exist.
  """
  def lookup(root_uuid, room_name, opts \\ [])
      when is_binary(root_uuid) and is_binary(room_name) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with {:ok, chat_dir_uuid} <- find_chat_dir(root_uuid, store),
         {:ok, room_dir_uuid} <- find_room_dir(chat_dir_uuid, room_name, store) do
      room_doc = load_schema(room_dir_uuid, store)

      # Pull each sub-doc UUID out of the room directory's schema.
      with {:ok, messages_entry} <- Schema.get_entry(room_doc, "_messages"),
           {:ok, reactions_entry} <- Schema.get_entry(room_doc, "_reactions"),
           {:ok, log_entry} <- Schema.get_entry(room_doc, "_messages.log"),
           {:ok, view_entry} <- Schema.get_entry(room_doc, "_view.xml") do
        {:ok,
         %{
           room_dir_uuid: room_dir_uuid,
           messages_uuid: messages_entry.node_id,
           reactions_uuid: reactions_entry.node_id,
           log_uuid: log_entry.node_id,
           view_uuid: view_entry.node_id
         }}
      else
        :error -> {:error, :not_found}
      end
    end
  end

  @doc """
  CX-tb7s (M3 sub-bead v): rewrite an existing chat room's `_view.xml`
  to the M3 shape. Idempotent — second call is a no-op (CommandRouter's
  `Diff.apply_diff/3` short-circuits on identical content).

  Existing pre-M3 rooms (created with the legacy template, kind="chat-room"
  hyphen, no <arg> children) survive M3 with a single migration call.
  Materializes existing `_messages` so the new view-XML body carries the
  current state (post/edit/delete chain-resolved).

  Returns `:ok` on success, `{:error, :not_found}` if the room doesn't
  exist, or `{:error, reason}` on write failures.
  """
  def upgrade_view_xml(root_uuid, room_name, opts \\ [])
      when is_binary(root_uuid) and is_binary(room_name) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    case lookup(root_uuid, room_name, store: store) do
      {:ok, room} ->
        materialized = materialize_messages(room.messages_uuid, store)
        new_content = ChatViewBuilder.build_view_xml(materialized, room_name)

        case CommandRouter.write(room.view_uuid, new_content) do
          {:ok, _info} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} = err ->
        err
    end
  end

  defp materialize_messages(messages_uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, messages_uuid) do
      {:ok, doc} ->
        Materialize.materialize(Messages.list(doc), ChatViewCompute.chain_rules())

      :none ->
        []
    end
  end

  # --- Private ---

  # Path-safe name: no slashes, no leading dot, non-empty. Mirrors the
  # `_`-prefix convention used by the substrate for "internal" entries
  # (which we don't allow chat rooms to shadow).
  defp validate_name(""), do: {:error, :invalid_name}
  defp validate_name("." <> _), do: {:error, :invalid_name}
  defp validate_name("_" <> _), do: {:error, :invalid_name}

  defp validate_name(name) do
    if String.contains?(name, "/") do
      {:error, :invalid_name}
    else
      :ok
    end
  end

  # Mint /chat directory if missing; return its uuid.
  defp ensure_chat_dir(root_uuid, store) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @chat_dir) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        chat_dir_uuid = UUID.uuid4()
        chat_dir_schema = Schema.new_schema()
        update = Yelixer.Encoding.encode_update(chat_dir_schema)
        CommitStoreClient.create_chained_commit(store, chat_dir_uuid, update)

        # Reload root and add the /chat entry.
        root_doc = load_schema(root_uuid, store)
        root_doc = Schema.add_directory(root_doc, @chat_dir, chat_dir_uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStoreClient.create_chained_commit(store, root_uuid, update)

        {:ok, chat_dir_uuid}
    end
  end

  defp ensure_not_exists(chat_dir_uuid, room_name, store) do
    chat_doc = load_schema(chat_dir_uuid, store)

    case Schema.get_entry(chat_doc, room_name) do
      :error -> :ok
      {:ok, _} -> {:error, :exists}
    end
  end

  defp find_chat_dir(root_uuid, store) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @chat_dir) do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> {:error, :not_found}
    end
  end

  defp find_room_dir(chat_dir_uuid, room_name, store) do
    chat_doc = load_schema(chat_dir_uuid, store)

    case Schema.get_entry(chat_doc, room_name) do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> {:error, :not_found}
    end
  end

  # Mint room directory + all sub-docs + room schema. Returns
  # {room_dir_uuid, %{messages_uuid, reactions_uuid, log_uuid, view_uuid}}.
  defp mint_room(room_name, store) do
    messages_uuid = mint_messages_doc(store)
    reactions_uuid = mint_reactions_doc(store)
    log_uuid = mint_log_doc(store)
    view_uuid = mint_view_doc(room_name, store)

    room_dir_uuid = UUID.uuid4()
    room_schema = Schema.new_schema()
    room_schema = Schema.add_file(room_schema, "_messages", messages_uuid)
    room_schema = Schema.add_file(room_schema, "_reactions", reactions_uuid)
    room_schema = Schema.add_file(room_schema, "_messages.log", log_uuid)
    room_schema = Schema.add_file(room_schema, "_view.xml", view_uuid)
    update = Yelixer.Encoding.encode_update(room_schema)
    CommitStoreClient.create_chained_commit(store, room_dir_uuid, update)

    {room_dir_uuid,
     %{
       messages_uuid: messages_uuid,
       reactions_uuid: reactions_uuid,
       log_uuid: log_uuid,
       view_uuid: view_uuid
     }}
  end

  defp mint_messages_doc(store) do
    uuid = UUID.uuid4()
    doc = Messages.new()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
    uuid
  end

  # Reactions live in a top-level YMap with composite-key boolean values
  # — the (β-revised) shape from chat-room.md a5f3f5e §Reactions.
  # CX-0trq: wrapped in a ContentType :map envelope so `cat` returns
  # the keyspace as a map (introspection-friendly) and the doc
  # self-describes via _root metadata. The composite-key contents are
  # unchanged.
  defp mint_reactions_doc(store) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, "_reactions")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
    uuid
  end

  # Red-channel onramp target. Same shape as RedLog's "events" YArray.
  defp mint_log_doc(store) do
    uuid = UUID.uuid4()
    doc = Commonplace.Dataflow.RedLog.new(uuid, store).doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
    uuid
  end

  # CX-tb7s (M3 sub-bead v): initial _view.xml shape comes from
  # ChatViewBuilder — single source of truth for the chat view-XML.
  # ChatViewCompute will overwrite this with materialized content on
  # first message, but the initial shape is already M3-canonical so
  # workspace claude reading the doc before any post sees the same
  # vocabulary.
  defp mint_view_doc(room_name, store) do
    uuid = UUID.uuid4()
    rendered = ChatViewBuilder.build_view_xml([], room_name)

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_view.xml")
    doc = ContentType.insert_text(doc, 0, rendered)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
    uuid
  end

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
