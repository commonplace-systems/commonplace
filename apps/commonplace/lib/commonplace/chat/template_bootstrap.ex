defmodule Commonplace.Chat.TemplateBootstrap do
  @moduledoc """
  CX-38fw (sub-bead i of CX-jfwv M4): chat-room template bootstrap.

  Mints `/chat/__template/` with the 4 canonical empty-seed sub-docs
  (`_messages`, `_reactions`, `_messages.log`, `_view.xml`) on first
  call. Subsequent calls are no-ops (idempotent — Anchor I).

  ## Why a separate module from Chat.Rooms

  Per the M4 spec held position #2 (template-as-prototype-doc-tree),
  the template is the source of truth that `Tree.Fork.fork_directory/2`
  deep-copies into each new chat room. The bootstrap is conceptually
  separate from per-room creation:

  * Per-app-installation infrastructure (this module): runs at app boot
    OR on first room-create call, mints the template once.
  * Per-room flow (`Chat.Rooms.create/3`): forks the template + adds
    the new room to the `/chat/` schema.

  ## Idempotence

  Checked at two levels:

  1. `/chat/__template/` schema entry exists → no-op.
  2. If somehow the entry exists but sub-docs are missing (corruption
     case), we DON'T attempt repair — leaves the operator to recover.
     Idempotence is for the no-corruption boot path.

  ## Path: `/chat/__template/`

  Per jes refinement (boss-clod msg 3247): per-app `__template`
  namespace under each app's directory. Future apps (`/wiki/__template/`,
  etc.) follow the same pattern. Substrate-tier `/__templates/`
  centralized namespace was rejected in favor of this colocation.

  ## __template name validation

  Already blocked by `Chat.Rooms`'s existing `_`-prefix rule
  (`validate_name/1` rejects names starting with `_`). No new
  validation rule code needed; `__template` is just a special case of
  the existing chat-tier reserved prefix.
  """

  alias Commonplace.Chat.{ChatViewBuilder, Messages}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @chat_dir "chat"
  @template_name "__template"

  @doc """
  Idempotently ensure `/chat/__template/` exists under `root_uuid`. If
  the template directory is already present, returns `:ok` without any
  new commits. Otherwise mints `/chat/` (if needed) and the template
  with all 4 canonical empty-seed sub-docs.

  Optional opts:
    * `:store` — CommitStore name (defaults to `CommitStoreClient`)
  """
  def ensure_template(root_uuid, opts \\ []) when is_binary(root_uuid) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with {:ok, chat_dir_uuid} <- ensure_chat_dir(root_uuid, store),
         :ok <- ensure_template_dir(chat_dir_uuid, store) do
      :ok
    end
  end

  # --- Private ---

  defp ensure_chat_dir(root_uuid, store) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, @chat_dir) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        chat_dir_uuid = UUID.uuid4()
        chat_schema = Schema.new_schema()
        update = Yelixer.Encoding.encode_update(chat_schema)
        CommitStoreClient.create_chained_commit(store, chat_dir_uuid, update)

        # Re-load root to chain off latest commit, then add /chat entry.
        root_doc = load_schema(root_uuid, store)
        root_doc = Schema.add_directory(root_doc, @chat_dir, chat_dir_uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStoreClient.create_chained_commit(store, root_uuid, update)

        {:ok, chat_dir_uuid}
    end
  end

  defp ensure_template_dir(chat_dir_uuid, store) do
    chat_doc = load_schema(chat_dir_uuid, store)

    case Schema.get_entry(chat_doc, @template_name) do
      {:ok, _entry} ->
        # Idempotent: template already minted, no-op.
        :ok

      :error ->
        mint_template(chat_dir_uuid, store)
    end
  end

  defp mint_template(chat_dir_uuid, store) do
    messages_uuid = mint_messages_doc(store)
    reactions_uuid = mint_reactions_doc(store)
    log_uuid = mint_log_doc(store)
    view_uuid = mint_view_doc(store)

    template_dir_uuid = UUID.uuid4()
    template_schema = Schema.new_schema()
    template_schema = Schema.add_file(template_schema, "_messages", messages_uuid)
    template_schema = Schema.add_file(template_schema, "_reactions", reactions_uuid)
    template_schema = Schema.add_file(template_schema, "_messages.log", log_uuid)
    template_schema = Schema.add_file(template_schema, "_view.xml", view_uuid)
    update = Yelixer.Encoding.encode_update(template_schema)
    CommitStoreClient.create_chained_commit(store, template_dir_uuid, update)

    # Add /chat/__template entry (chain off latest /chat schema).
    chat_doc = load_schema(chat_dir_uuid, store)
    chat_doc = Schema.add_directory(chat_doc, @template_name, template_dir_uuid)
    update = Yelixer.Encoding.encode_update(chat_doc)
    CommitStoreClient.create_chained_commit(store, chat_dir_uuid, update)

    :ok
  end

  defp mint_messages_doc(store) do
    uuid = UUID.uuid4()
    doc = Messages.new()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
    uuid
  end

  defp mint_reactions_doc(store) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, "_reactions")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
    uuid
  end

  defp mint_log_doc(store) do
    uuid = UUID.uuid4()
    doc = Commonplace.Dataflow.RedLog.new(uuid, store).doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
    uuid
  end

  defp mint_view_doc(store) do
    uuid = UUID.uuid4()
    rendered = ChatViewBuilder.build_view_xml([], @template_name)

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
