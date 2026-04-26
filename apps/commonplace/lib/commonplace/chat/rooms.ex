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

  alias Commonplace.Chat.{ChatViewBuilder, Messages, TemplateBootstrap}
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
    # _compute optional for pre-M5 templates that haven't migrated yet
    # (TemplateBootstrap idempotently adds it; rooms forked after that
    # will have it). lookup_optional_child returns nil if missing.
    with {:ok, primary} <-
           Lookup.extract_named_children(
             room_dir_uuid,
             ["_messages", "_reactions", "_messages.log", "_view.xml"],
             opts
           ) do
      {:ok,
       %{
         messages_uuid: primary["_messages"],
         reactions_uuid: primary["_reactions"],
         log_uuid: primary["_messages.log"],
         view_uuid: primary["_view.xml"],
         compute_uuid: lookup_optional_child(room_dir_uuid, "_compute", opts)
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
    # CX-h4mc (M5 sub-bead iv): _compute is the 5th canonical sub-doc
    # (M5 sub-bead i added it to /chat/__template/). For pre-M5 rooms
    # missing _compute, lookup falls back to nil — Chat.Rooms.upgrade_compute
    # adds it on demand.
    primary_names = ["_messages", "_reactions", "_messages.log", "_view.xml"]

    with {:ok, room_dir_uuid} <- Lookup.lookup_doc_by_path(root_uuid, path, opts),
         {:ok, primary} <- Lookup.extract_named_children(room_dir_uuid, primary_names, opts) do
      compute_uuid = lookup_optional_child(room_dir_uuid, "_compute", opts)

      {:ok,
       %{
         room_dir_uuid: room_dir_uuid,
         messages_uuid: primary["_messages"],
         reactions_uuid: primary["_reactions"],
         log_uuid: primary["_messages.log"],
         view_uuid: primary["_view.xml"],
         compute_uuid: compute_uuid
       }}
    else
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp lookup_optional_child(parent_uuid, name, opts) do
    case Lookup.extract_named_children(parent_uuid, [name], opts) do
      {:ok, %{^name => uuid}} -> uuid
      _ -> nil
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

  @doc """
  CX-h4mc (M5 sub-bead iv): per-room migration helper for pre-M5 rooms.
  Pre-M5 rooms (created during M4) lack the `_compute` sub-doc. This
  helper forks `/chat/__template/_compute` (added by M5 sub-bead i)
  and adds the resulting doc to the room directory's schema.

  Idempotent — second call no-ops if `_compute` is already present.

  Returns `:ok` on success, `{:error, :not_found}` if the room or
  template doesn't exist.
  """
  def upgrade_compute(root_uuid, room_name, opts \\ [])
      when is_binary(root_uuid) and is_binary(room_name) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with {:ok, room} <- lookup(root_uuid, room_name, opts) do
      if room.compute_uuid do
        :ok
      else
        with :ok <- TemplateBootstrap.ensure_template(root_uuid, opts),
             {:ok, template_compute_uuid} <-
               Lookup.lookup_doc_by_path(
                 root_uuid,
                 "#{@chat_dir}/__template/_compute",
                 opts
               ) do
          forked_compute_uuid = Fork.fork_directory(template_compute_uuid, store)

          room_doc = load_schema(room.room_dir_uuid, store)
          room_doc = Schema.add_file(room_doc, "_compute", forked_compute_uuid)
          update = Yelixer.Encoding.encode_update(room_doc)
          CommitStoreClient.create_chained_commit(store, room.room_dir_uuid, update)

          :ok
        end
      end
    end
  end

  # Materialize chain rules read from the per-room _compute spec doc
  # when present (M5); falls back to inline default rules for pre-M5
  # rooms that haven't been migrated via upgrade_compute.
  defp materialize_messages(messages_uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, messages_uuid) do
      {:ok, doc} ->
        Materialize.materialize(Messages.list(doc), default_chain_rules())

      :none ->
        []
    end
  end

  # Pre-M5 inline chain rules — kept here as the data-only fallback for
  # `upgrade_view_xml` callers that don't pass spec-derived rules.
  # ChatViewCompute Elixir module is gone (M5 (iv) DELETE); these data
  # live with the chat-tier callers that need them. Substrate-pure
  # consumers read chain rules from per-room `_compute` spec doc via
  # ComputeSpec.
  defp default_chain_rules do
    %{
      chains: [
        %{field: "edit_of", semantics: :latest_replaces},
        %{field: "tombstone_of", semantics: :marks_deleted}
      ]
    }
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
