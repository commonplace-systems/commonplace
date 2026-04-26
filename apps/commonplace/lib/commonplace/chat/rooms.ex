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

  alias Commonplace.Chat.{ChatViewBuilder, ChatViewCompute, Messages, TemplateBootstrap}
  alias Commonplace.CommandRouter
  alias Commonplace.Materialize
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Fork, Lookup, Schema}

  @chat_dir "chat"

  @doc """
  Create a chat room under `/chat/{room_name}/`. Returns the UUIDs of
  the room directory and all canonical sub-docs.

  CX-dvba (M4 sub-bead iii — keystone): pure substrate operation. Forks
  the chat-room template at `/chat/__template/` via
  `Tree.Fork.fork_directory/2`; customizes `_view.xml` with the new
  room name; adds the room to the `/chat` schema. Six lines of
  orchestration over substrate primitives.

  Lazy template-ensure: `TemplateBootstrap.ensure_template/2` runs at
  app boot AND idempotently here so test/CLI environments without a
  boot-fired ensure get a working template on first room create.

  Optional opts:
    * `:store` — CommitStore name (defaults to `CommitStoreClient`)

  Errors:
    * `{:error, :exists}` — room name is already taken under `/chat/`
    * `{:error, :invalid_name}` — name fails the path-safe check
      (empty, leading dot/underscore, contains slash)
  """
  def create(root_uuid, room_name, opts \\ [])
      when is_binary(root_uuid) and is_binary(room_name) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    template_path = "#{@chat_dir}/__template"

    with :ok <- validate_name(room_name),
         :ok <- TemplateBootstrap.ensure_template(root_uuid, opts),
         {:ok, chat_dir_uuid} <- Lookup.lookup_doc_by_path(root_uuid, @chat_dir, opts),
         :ok <- ensure_not_exists(chat_dir_uuid, room_name, store),
         {:ok, template_uuid} <- Lookup.lookup_doc_by_path(root_uuid, template_path, opts) do
      room_dir_uuid = Fork.fork_directory(template_uuid, store)
      {:ok, sub_docs} = lookup_room_children(room_dir_uuid, opts)
      :ok = customize_view_xml(sub_docs.view_uuid, room_name, store)
      :ok = add_to_chat_schema(chat_dir_uuid, room_name, room_dir_uuid, store)

      {:ok, Map.put(sub_docs, :room_dir_uuid, room_dir_uuid)}
    end
  end

  defp lookup_room_children(room_dir_uuid, opts) do
    with {:ok, children} <-
           Lookup.extract_named_children(
             room_dir_uuid,
             ["_messages", "_reactions", "_messages.log", "_view.xml"],
             opts
           ) do
      {:ok,
       %{
         messages_uuid: children["_messages"],
         reactions_uuid: children["_reactions"],
         log_uuid: children["_messages.log"],
         view_uuid: children["_view.xml"]
       }}
    end
  end

  # Direct store-aware write so create/3's per-test :store opts thread
  # through. CommandRouter.write (used by upgrade_view_xml) routes to
  # the production-named CommitStore — fine for runtime, but tests
  # using a separate named CommitStore need the explicit store
  # parameter.
  defp customize_view_xml(view_uuid, room_name, store) do
    rendered = ChatViewBuilder.build_view_xml([], room_name)

    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, view_uuid)
    current = Commonplace.Document.ContentType.get_content(doc) || ""
    length = String.length(current)

    doc =
      doc
      |> Commonplace.Document.ContentType.delete_text(0, length)
      |> Commonplace.Document.ContentType.insert_text(0, rendered)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, view_uuid, update)
    :ok
  end

  defp add_to_chat_schema(chat_dir_uuid, room_name, room_dir_uuid, store) do
    chat_schema = load_schema(chat_dir_uuid, store)
    chat_schema = Schema.add_directory(chat_schema, room_name, room_dir_uuid)
    update = Yelixer.Encoding.encode_update(chat_schema)
    CommitStoreClient.create_chained_commit(store, chat_dir_uuid, update)
    :ok
  end

  @doc """
  Resolve a room name to its sub-doc UUIDs by walking the workspace
  schema. Returns `{:error, :not_found}` if the room (or the `/chat`
  directory itself) doesn't exist.

  CX-j6ul (M4 sub-bead ii): thin wrapper over the substrate-tier
  `Commonplace.Tree.Lookup.lookup_path_and_extract/4`. The chat-tier
  shape (path-walk + named-children-extraction) generalized cleanly.
  """
  def lookup(root_uuid, room_name, opts \\ [])
      when is_binary(root_uuid) and is_binary(room_name) and is_list(opts) do
    path = "#{@chat_dir}/#{room_name}"
    names = ["_messages", "_reactions", "_messages.log", "_view.xml"]

    with {:ok, room_dir_uuid} <- Lookup.lookup_doc_by_path(root_uuid, path, opts),
         {:ok, children} <- Lookup.extract_named_children(room_dir_uuid, names, opts) do
      {:ok,
       %{
         room_dir_uuid: room_dir_uuid,
         messages_uuid: children["_messages"],
         reactions_uuid: children["_reactions"],
         log_uuid: children["_messages.log"],
         view_uuid: children["_view.xml"]
       }}
    else
      {:error, _reason} -> {:error, :not_found}
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

  defp ensure_not_exists(chat_dir_uuid, room_name, store) do
    chat_doc = load_schema(chat_dir_uuid, store)

    case Schema.get_entry(chat_doc, room_name) do
      :error -> :ok
      {:ok, _} -> {:error, :exists}
    end
  end

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
