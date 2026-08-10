defmodule Commonplace.MCP.Tools.LoomTest do
  @moduledoc """
  CX-6sf2.1 (A1): `#loom` as a first-class commonplace chat room reached
  via MCP tools `loom_send` / `loom_read`.

  Follows the isolated-store setup pattern from
  `invoke_view_action_chat_integration_test.exs` — per-test scratch
  data_dir + CommitStore restart, root schema doc bootstrapped with a
  fresh UUID written to `<dir>/root` (what `Workspace.root_uuid/0`
  reads).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{LoomRoom, Rooms}
  alias Commonplace.MCP.Tools
  alias Commonplace.MCP.Tools.{LoomRead, LoomSend}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_loom_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    %{root: root_uuid}
  end

  describe "loom_send" do
    test "posts a message that appears in the loom room's _messages, attributed per ctx", %{
      root: root
    } do
      ctx = %{presence_path: "alice.usr"}

      assert {:ok, result} = LoomSend.run(%{"text" => "hello loom"}, ctx)
      assert result["isError"] == false

      {:ok, room} = LoomRoom.ensure(root)

      {:ok, doc} =
        Commonplace.Tree.DocBuilder.reconstruct_snapshot(CommitStoreClient, room.messages_uuid)

      [msg] = Commonplace.Chat.Messages.materialize(doc)

      assert msg["text"] == "hello loom"
      assert msg["author_path"] == "alice.usr"
    end

    test "idempotent room ensure — two sends don't create two rooms", %{root: root} do
      {:ok, _} = LoomSend.run(%{"text" => "first"}, %{presence_path: "alice.usr"})
      {:ok, _} = LoomSend.run(%{"text" => "second"}, %{presence_path: "alice.usr"})

      {:ok, room_1} = Rooms.lookup(root, LoomRoom.room_name())
      {:ok, room_2} = Rooms.lookup(root, LoomRoom.room_name())

      assert room_1.room_dir_uuid == room_2.room_dir_uuid

      {:ok, doc} =
        Commonplace.Tree.DocBuilder.reconstruct_snapshot(CommitStoreClient, room_1.messages_uuid)

      messages = Commonplace.Chat.Messages.materialize(doc)
      assert length(messages) == 2
    end

    test "rejects missing/non-string text" do
      assert {:error, :invalid_params, _} = LoomSend.run(%{}, %{})
      assert {:error, :invalid_params, _} = LoomSend.run(%{"text" => 123}, %{})
    end
  end

  describe "loom_read" do
    test "no cursor returns recent messages + a cursor", %{root: root} do
      {:ok, _} = LoomSend.run(%{"text" => "m1"}, %{presence_path: "alice.usr"})
      {:ok, _} = LoomSend.run(%{"text" => "m2"}, %{presence_path: "alice.usr"})

      assert {:ok, result} = LoomRead.run(%{}, %{})
      structured = structured_payload(result)

      assert length(structured["messages"]) == 2
      assert is_binary(structured["cursor"])
      assert structured["cursor"] == List.last(structured["messages"])["id"]

      _ = root
    end

    test "with a cursor returns only messages after it; cursor advances", %{root: _root} do
      {:ok, _} = LoomSend.run(%{"text" => "m1"}, %{presence_path: "alice.usr"})
      {:ok, _} = LoomSend.run(%{"text" => "m2"}, %{presence_path: "alice.usr"})
      {:ok, _} = LoomSend.run(%{"text" => "m3"}, %{presence_path: "alice.usr"})

      {:ok, first_page} = LoomRead.run(%{}, %{})
      all_msgs = structured_payload(first_page)["messages"]
      cursor_after_m1 = Enum.at(all_msgs, 0)["id"]

      assert {:ok, second_page} = LoomRead.run(%{"since" => cursor_after_m1}, %{})
      structured = structured_payload(second_page)

      texts = Enum.map(structured["messages"], & &1["text"])
      assert texts == ["m2", "m3"]
      assert structured["cursor"] == Enum.at(all_msgs, 2)["id"]
    end
  end

  describe "tool registry" do
    test "loom_send and loom_read appear in Tools.list" do
      names = Tools.list() |> Enum.map(& &1["name"])
      assert "loom_send" in names
      assert "loom_read" in names
    end
  end

  defp structured_payload(result) do
    result["content"]
    |> Enum.at(1)
    |> Map.get("text")
    |> Jason.decode!()
  end
end
