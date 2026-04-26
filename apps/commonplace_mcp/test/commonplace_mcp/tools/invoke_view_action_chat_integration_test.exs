defmodule Commonplace.MCP.Tools.InvokeViewActionChatIntegrationTest do
  @moduledoc """
  CX-waid (sub-bead iii of CX-04d8 M3): proves the substrate ArgResolver
  cashes the M1 banked lesson — workspace claude can call
  `invoke_view_action(view_path, action: "post_message", args: {text})`
  with MINIMAL args and the substrate auto-resolves messages_uuid /
  messages_log_uuid / room / author_path from the view's `<arg>`
  declarations.

  Chat-path Anchor A from the M3 spec. Pre-(iii) this would have RED'd;
  post-(iii) the resolution flows through `Commonplace.View.ArgResolver`
  with NO chat-specific resolver code in the call path.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{Actions, Messages, Rooms}
  alias Commonplace.Document.ContentType
  alias Commonplace.MCP.Tools.InvokeViewAction
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    # Per-test scratch dir + CommitStore restart. Restore to the
    # test-config default ("tmp/test_data") in on_exit — captured-prior
    # is racy under parallel async:false execution (see
    # chat_view_compute_supervisor_test.exs).
    dir =
      Path.join(System.tmp_dir!(), "cp_invoke_view_action_chat_#{:rand.uniform(1_000_000_000)}")

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
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(
          sup,
          {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"}
        )

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    {:ok, room} = Rooms.create(root_uuid, "general")

    view_content = read_view_content(room.view_uuid)

    %{root: root_uuid, room: room, view_content: view_content}
  end

  defp read_view_content(view_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, view_uuid)
    ContentType.get_content(doc)
  end

  describe "post_message — substrate ArgResolver path (Anchor A)" do
    test "minimal MCP args (just text) → message lands; substrate resolves via <arg>",
         %{room: room, view_content: view_content} do
      mcp_args = %{
        "view_path" => "/chat/general/_view.xml",
        "args" => %{"text" => "hi from MCP minimal-args path"}
      }

      session_context = %{presence_path: "alice.usr"}

      assert {:ok, _result} =
               InvokeViewAction.run_with_content(
                 view_content,
                 room.view_uuid,
                 "post_message",
                 mcp_args,
                 session_context
               )

      messages = load_messages(room.messages_uuid)
      assert length(messages) == 1

      [msg] = messages
      assert msg["text"] == "hi from MCP minimal-args path"
      assert msg["author_path"] == "alice.usr"
    end

    test "caller-supplied messages_uuid wins over <arg from='../_messages'/>",
         %{room: room, view_content: view_content} do
      # Create a SECOND messages doc — caller-supplied uuid should land there
      # rather than at room.messages_uuid (the <arg from> resolution target).
      other_uuid = UUID.uuid4()
      other_doc = Messages.new()
      update = Yelixer.Encoding.encode_update(other_doc)
      CommitStore.create_commit(Commonplace.Store.CommitStore, other_uuid, update, nil)

      mcp_args = %{
        "view_path" => "/chat/general/_view.xml",
        "args" => %{
          "text" => "explicit-uuid wins",
          "messages_uuid" => other_uuid,
          "author_path" => "explicit-author.usr"
        }
      }

      assert {:ok, _result} =
               InvokeViewAction.run_with_content(
                 view_content,
                 room.view_uuid,
                 "post_message",
                 mcp_args,
                 %{presence_path: "from-session.usr"}
               )

      # Auto-resolved room.messages_uuid should be EMPTY (caller's uuid won)
      assert load_messages(room.messages_uuid) == []

      # Caller's other_uuid should have the message with the explicit author
      [msg] = load_messages(other_uuid)
      assert msg["author_path"] == "explicit-author.usr"
    end
  end

  describe "edit_message — substrate ArgResolver path" do
    test "minimal MCP args (message_id + text) → edit lands; substrate auto-resolves",
         %{room: room, view_content: view_content} do
      # Seed the room with one message so we have something to edit.
      {:ok, %{message_id: m1}} =
        Actions.post_message(room.messages_uuid, "v1",
          room: "general",
          signer_id: "seed",
          author_path: "alice.usr"
        )

      mcp_args = %{
        "view_path" => "/chat/general/_view.xml",
        "args" => %{"message_id" => m1, "text" => "v2"}
      }

      assert {:ok, _result} =
               InvokeViewAction.run_with_content(
                 view_content,
                 room.view_uuid,
                 "edit_message",
                 mcp_args,
                 %{presence_path: "alice.usr"}
               )

      [view] = Messages.materialize(load_messages_doc(room.messages_uuid))
      assert view["text"] == "v2", "edit chain tip's text should win"
      assert view["edited?"] == true
    end
  end

  describe "delete_message — substrate ArgResolver path" do
    test "minimal MCP args (message_id) → tombstone lands",
         %{room: room, view_content: view_content} do
      {:ok, %{message_id: m1}} =
        Actions.post_message(room.messages_uuid, "to be deleted",
          room: "general",
          signer_id: "seed",
          author_path: "alice.usr"
        )

      mcp_args = %{
        "view_path" => "/chat/general/_view.xml",
        "args" => %{"message_id" => m1}
      }

      assert {:ok, _result} =
               InvokeViewAction.run_with_content(
                 view_content,
                 room.view_uuid,
                 "delete_message",
                 mcp_args,
                 %{presence_path: "alice.usr"}
               )

      [view] = Messages.materialize(load_messages_doc(room.messages_uuid))
      assert view["deleted?"] == true
    end
  end

  defp load_messages_doc(messages_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid)
    doc
  end

  defp load_messages(messages_uuid) do
    Messages.list(load_messages_doc(messages_uuid))
  end
end
