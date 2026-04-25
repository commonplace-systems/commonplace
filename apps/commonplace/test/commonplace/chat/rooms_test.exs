defmodule Commonplace.Chat.RoomsTest do
  @moduledoc """
  CX-71o3 (C1 of CX-p2qp): chat room lifecycle helper.

  `Commonplace.Chat.Rooms.create/2` initializes the canonical chat-room
  layout under `/chat/{name}/` per chat-room.md (commit bb83a1b on
  commonplace-plan/main): directory entry, `_messages` (top-level YArray
  of JSON entries), `_reactions` (top-level YMap with composite keys),
  `_messages.log` (red onramp target), `_view.xml` (action declarations
  + composer chrome). MVP scope is intentionally minimal — no
  permissions, no metadata, no auto-subscribe.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.Rooms
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_chat_rooms_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"chat_rooms_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    # Seed an empty workspace root.
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  describe "create/3" do
    test "initializes the room directory and all canonical sub-docs",
         %{store: store, root: root} do
      assert {:ok, room} = Rooms.create(root, "general", store: store)

      assert is_binary(room.room_dir_uuid)
      assert is_binary(room.messages_uuid)
      assert is_binary(room.reactions_uuid)
      assert is_binary(room.log_uuid)
      assert is_binary(room.view_uuid)
    end

    test "attaches /chat/{room}/ under the workspace root via schema",
         %{store: store, root: root} do
      {:ok, room} = Rooms.create(root, "general", store: store)

      {:ok, root_doc} = DocBuilder.reconstruct_snapshot(store, root)
      {:ok, chat_entry} = Schema.get_entry(root_doc, "chat")
      assert chat_entry.type == :dir

      {:ok, chat_doc} = DocBuilder.reconstruct_snapshot(store, chat_entry.node_id)
      {:ok, room_entry} = Schema.get_entry(chat_doc, "general")
      assert room_entry.type == :dir
      assert room_entry.node_id == room.room_dir_uuid
    end

    test "the room directory contains _messages, _reactions, _messages.log, _view.xml",
         %{store: store, root: root} do
      {:ok, room} = Rooms.create(root, "general", store: store)

      {:ok, dir_doc} = DocBuilder.reconstruct_snapshot(store, room.room_dir_uuid)

      {:ok, messages_entry} = Schema.get_entry(dir_doc, "_messages")
      assert messages_entry.node_id == room.messages_uuid
      assert messages_entry.type == :doc

      {:ok, reactions_entry} = Schema.get_entry(dir_doc, "_reactions")
      assert reactions_entry.node_id == room.reactions_uuid

      {:ok, log_entry} = Schema.get_entry(dir_doc, "_messages.log")
      assert log_entry.node_id == room.log_uuid

      {:ok, view_entry} = Schema.get_entry(dir_doc, "_view.xml")
      assert view_entry.node_id == room.view_uuid
    end

    test "_view.xml declares all three chat actions", %{store: store, root: root} do
      {:ok, room} = Rooms.create(root, "general", store: store)

      content = read_text_doc(store, room.view_uuid)

      assert content =~ ~s(name="post_message")
      assert content =~ ~s(name="edit_message")
      assert content =~ ~s(name="delete_message")
    end

    test "creates a second room without disturbing the first",
         %{store: store, root: root} do
      {:ok, _r1} = Rooms.create(root, "general", store: store)
      assert {:ok, r2} = Rooms.create(root, "loom", store: store)

      assert is_binary(r2.messages_uuid)

      # Both rooms reachable via schema.
      {:ok, root_doc} = DocBuilder.reconstruct_snapshot(store, root)
      {:ok, chat_entry} = Schema.get_entry(root_doc, "chat")
      {:ok, chat_doc} = DocBuilder.reconstruct_snapshot(store, chat_entry.node_id)

      assert {:ok, _} = Schema.get_entry(chat_doc, "general")
      assert {:ok, _} = Schema.get_entry(chat_doc, "loom")
    end

    test "duplicate room names return {:error, :exists}",
         %{store: store, root: root} do
      {:ok, _} = Rooms.create(root, "general", store: store)
      assert {:error, :exists} = Rooms.create(root, "general", store: store)
    end

    # CX-0trq regression: _messages and _reactions must be ContentType
    # envelopes so MCP cat tool returns structured content (not null/null/null).
    test "_messages doc has a ContentType :array envelope (cat-able)",
         %{store: store, root: root} do
      {:ok, room} = Rooms.create(root, "general", store: store)

      {:ok, doc} = DocBuilder.reconstruct_snapshot(store, room.messages_uuid)
      assert Commonplace.Document.ContentType.get_type(doc) == :array
      assert Commonplace.Document.ContentType.get_meta(doc, "_name") == "_messages"
    end

    test "_reactions doc has a ContentType :map envelope (cat-able)",
         %{store: store, root: root} do
      {:ok, room} = Rooms.create(root, "general", store: store)

      {:ok, doc} = DocBuilder.reconstruct_snapshot(store, room.reactions_uuid)
      assert Commonplace.Document.ContentType.get_type(doc) == :map
      assert Commonplace.Document.ContentType.get_meta(doc, "_name") == "_reactions"
    end

    test "rejects path-unsafe room names (slashes, leading dots)",
         %{store: store, root: root} do
      assert {:error, :invalid_name} = Rooms.create(root, "with/slash", store: store)
      assert {:error, :invalid_name} = Rooms.create(root, ".hidden", store: store)
      assert {:error, :invalid_name} = Rooms.create(root, "", store: store)
    end
  end

  describe "lookup/3" do
    test "resolves a room name to its sub-doc UUIDs", %{store: store, root: root} do
      {:ok, created} = Rooms.create(root, "general", store: store)
      assert {:ok, found} = Rooms.lookup(root, "general", store: store)

      assert found.room_dir_uuid == created.room_dir_uuid
      assert found.messages_uuid == created.messages_uuid
      assert found.reactions_uuid == created.reactions_uuid
      assert found.log_uuid == created.log_uuid
      assert found.view_uuid == created.view_uuid
    end

    test "returns {:error, :not_found} for unknown rooms",
         %{store: store, root: root} do
      assert {:error, :not_found} = Rooms.lookup(root, "nonexistent", store: store)
    end

    test "returns {:error, :not_found} when /chat dir doesn't exist",
         %{store: store, root: root} do
      # No rooms created — /chat sub-dir was never minted.
      assert {:error, :not_found} = Rooms.lookup(root, "general", store: store)
    end
  end

  defp read_text_doc(store, uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
    Commonplace.Document.ContentType.get_content(doc) || ""
  end
end
