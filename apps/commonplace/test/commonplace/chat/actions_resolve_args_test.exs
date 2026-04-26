defmodule Commonplace.Chat.ActionsResolveArgsTest do
  @moduledoc """
  CX-icc2 (sub-bead i of CX-8cw5 milestone 1): unit tests for
  Commonplace.Chat.Actions.resolve_args/4.

  Per consensus #3115 → #3135: shape (a) hardcoded resolvers, optional
  view_path, caller-wins maybe_put semantics, explicit error on bad
  view_path (not silent fallback).

  Resolver maps action + supplied args + view_uuid + session context →
  fully-resolved args. Three branches:

  * view_path absent → {:ok, args_unchanged} (no resolution attempted)
  * view_path supplied + resolves cleanly → {:ok, args_with_resolutions}
  * view_path supplied + resolution fails → {:error, reason}
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{Actions, Rooms}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    # The resolver reads workspace root via Workspace.root_uuid (data_dir
    # file) and uses CommitStoreClient which routes to the production-
    # named Commonplace.Store.CommitStore. Mirror the wiki_live_test.exs
    # pattern: repoint both at a per-test scratch dir.
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    dir = Path.join(System.tmp_dir!(), "cp_resolve_args_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, prior_data_dir)

      _ =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: prior_data_dir})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    {:ok, room} = Rooms.create(root_uuid, "general")

    %{root: root_uuid, room: room, view_path: "chat/general/_view.xml"}
  end

  describe "resolve_args/4 — view_path supplied + clean room" do
    test "resolves all four substrate-derived args from view_path",
         %{room: room, view_path: vp} do
      args = %{"text" => "hello"}
      ctx = %{view_path: vp, presence_path: "alice.usr"}

      assert {:ok, resolved} =
               Actions.resolve_args("post_message", args, room.view_uuid, ctx)

      assert resolved["text"] == "hello"
      assert resolved["messages_uuid"] == room.messages_uuid
      assert resolved["messages_log_uuid"] == room.log_uuid
      assert resolved["room"] == "general"
      assert resolved["author_path"] == "alice.usr"
    end

    test "edit_message resolves the same way as post_message",
         %{room: room, view_path: vp} do
      args = %{"text" => "v2", "message_id" => "m1"}
      ctx = %{view_path: vp, presence_path: "bob.usr"}

      assert {:ok, resolved} =
               Actions.resolve_args("edit_message", args, room.view_uuid, ctx)

      assert resolved["messages_uuid"] == room.messages_uuid
      assert resolved["author_path"] == "bob.usr"
      assert resolved["message_id"] == "m1"
    end

    test "delete_message resolves the same way",
         %{room: room, view_path: vp} do
      args = %{"message_id" => "m1"}
      ctx = %{view_path: vp, presence_path: "alice.usr"}

      assert {:ok, resolved} =
               Actions.resolve_args("delete_message", args, room.view_uuid, ctx)

      assert resolved["messages_uuid"] == room.messages_uuid
    end
  end

  describe "resolve_args/4 — caller-wins precedence" do
    test "caller-supplied messages_uuid wins over substrate resolution",
         %{room: room, view_path: vp} do
      args = %{
        "text" => "hi",
        "messages_uuid" => "explicit-overriding-uuid"
      }

      ctx = %{view_path: vp, presence_path: "alice.usr"}

      assert {:ok, resolved} =
               Actions.resolve_args("post_message", args, room.view_uuid, ctx)

      assert resolved["messages_uuid"] == "explicit-overriding-uuid"
      # But author_path still resolves (since caller didn't supply it)
      assert resolved["author_path"] == "alice.usr"
    end

    test "caller-supplied author_path wins over presence_path resolution",
         %{room: room, view_path: vp} do
      args = %{"text" => "hi", "author_path" => "manual.usr"}
      ctx = %{view_path: vp, presence_path: "session.bot"}

      assert {:ok, resolved} =
               Actions.resolve_args("post_message", args, room.view_uuid, ctx)

      assert resolved["author_path"] == "manual.usr"
    end

    test "fully-explicit args pass through unchanged (ChatRoomLive's path)",
         %{room: room, view_path: vp} do
      args = %{
        "text" => "explicit",
        "messages_uuid" => "x",
        "messages_log_uuid" => "y",
        "room" => "z",
        "author_path" => "w"
      }

      ctx = %{view_path: vp, presence_path: "ignored"}

      assert {:ok, resolved} =
               Actions.resolve_args("post_message", args, room.view_uuid, ctx)

      assert resolved == args
    end
  end

  describe "resolve_args/4 — view_path absent" do
    test "no view_path → pass-through; resolution not attempted",
         %{room: room} do
      args = %{"text" => "hi"}
      ctx = %{presence_path: "alice.usr"}

      assert {:ok, resolved} =
               Actions.resolve_args("post_message", args, room.view_uuid, ctx)

      assert resolved == args,
             "args should pass through unchanged when view_path is absent"
    end
  end

  describe "resolve_args/4 — bad view_path errors explicitly" do
    test "view_path pointing to nonexistent room returns {:error, reason}",
         %{room: room} do
      args = %{"text" => "hi"}
      ctx = %{view_path: "chat/nonexistent/_view.xml", presence_path: "alice.usr"}

      assert {:error, reason} =
               Actions.resolve_args("post_message", args, room.view_uuid, ctx)

      assert is_binary(reason)
      assert reason =~ "auto-resolution"
    end
  end

  describe "resolve_args/4 — non-chat actions" do
    test "unknown action passes args through unchanged", %{room: room} do
      args = %{"foo" => "bar"}
      ctx = %{view_path: "chat/general/_view.xml", presence_path: "alice.usr"}

      assert {:ok, resolved} =
               Actions.resolve_args("not_a_chat_action", args, room.view_uuid, ctx)

      assert resolved == args
    end
  end
end
