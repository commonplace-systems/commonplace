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

  # CX-9tj0 (M7 sub-bead iv): canonical chat compute source. The Elixir
  # source IS the pipeline; substrate ComputeRunner reads + compiles +
  # calls module.compute(raw, ctx). Module attribute declared here so
  # both mint_compute_doc + ensure_compute_in_template's upgrade path
  # share one source-of-truth string. Public accessor at
  # `chat_compute_source/0` lets `Chat.Rooms.upgrade_compute_to_m7/3`
  # reuse the same string for per-room migration.
  @chat_compute_source ~S"""
  defmodule Commonplace.UserCode.Chat.Compute do
    alias Commonplace.Compute

    def compute(raw, ctx) do
      raw
      |> Compute.decode_json_array()
      |> Compute.materialize(chains: [
        {:edit_of, :latest_replaces},
        {:tombstone_of, :marks_deleted}
      ])
      |> Commonplace.Chat.ChatViewBuilder.build_view_xml(ctx.room_name)
    end
  end
  """

  @doc """
  Public accessor for the canonical chat compute source. Used by
  `Chat.Rooms.upgrade_compute_to_m7/3` (per-room migration).
  """
  def chat_compute_source, do: @chat_compute_source

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
      {:ok, entry} ->
        # CX-qbhb (M5 sub-bead i): existing template may be pre-M5 and
        # lack the _compute spec doc. Migrate forward by adding _compute
        # if missing. Idempotent: if _compute already there, no-op.
        ensure_compute_in_template(entry.node_id, store)

      :error ->
        mint_template(chat_dir_uuid, store)
    end
  end

  # CX-9tj0 (M7 sub-bead iv): _compute body shifted XML→Elixir source
  # for the M7 ComputeRunner path. Idempotent migration:
  # - if _compute missing → mint with Elixir body
  # - if _compute exists with XML body (M5/M6 ship) → upgrade body to Elixir
  # - if _compute exists with Elixir body (post-M7) → no-op
  defp ensure_compute_in_template(template_dir_uuid, store) do
    template_doc = load_schema(template_dir_uuid, store)

    case Schema.get_entry(template_doc, "_compute") do
      {:ok, entry} ->
        upgrade_compute_body_if_xml(entry.node_id, store)

      :error ->
        compute_uuid = mint_compute_doc(store)
        template_doc = load_schema(template_dir_uuid, store)
        template_doc = Schema.add_file(template_doc, "_compute", compute_uuid)
        update = Yelixer.Encoding.encode_update(template_doc)
        CommitStoreClient.create_chained_commit(store, template_dir_uuid, update)
        :ok
    end
  end

  # Detect XML-vs-Elixir body via leading-`<` heuristic; upgrade XML
  # bodies to Elixir source. Idempotent — bodies starting with non-`<`
  # are assumed Elixir and left alone.
  defp upgrade_compute_body_if_xml(compute_uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, compute_uuid) do
      {:ok, doc} ->
        content = ContentType.get_content(doc) || ""

        if xml_body?(content) do
          rewrite_compute_doc(compute_uuid, doc, content, store)
        else
          :ok
        end

      :none ->
        :ok
    end
  end

  defp xml_body?(content) do
    content
    |> String.trim_leading()
    |> String.starts_with?("<")
  end

  defp rewrite_compute_doc(compute_uuid, doc, current_content, store) do
    length = String.length(current_content)

    doc =
      doc
      |> ContentType.delete_text(0, length)
      |> ContentType.insert_text(0, @chat_compute_source)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, compute_uuid, update)
    :ok
  end

  defp mint_template(chat_dir_uuid, store) do
    messages_uuid = mint_messages_doc(store)
    reactions_uuid = mint_reactions_doc(store)
    log_uuid = mint_log_doc(store)
    view_uuid = mint_view_doc(store)
    compute_uuid = mint_compute_doc(store)

    template_dir_uuid = UUID.uuid4()
    template_schema = Schema.new_schema()
    template_schema = Schema.add_file(template_schema, "_messages", messages_uuid)
    template_schema = Schema.add_file(template_schema, "_reactions", reactions_uuid)
    template_schema = Schema.add_file(template_schema, "_messages.log", log_uuid)
    template_schema = Schema.add_file(template_schema, "_view.xml", view_uuid)
    template_schema = Schema.add_file(template_schema, "_compute", compute_uuid)
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


  defp mint_compute_doc(store) do
    uuid = UUID.uuid4()

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_compute")
    doc = ContentType.insert_text(doc, 0, @chat_compute_source)
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
