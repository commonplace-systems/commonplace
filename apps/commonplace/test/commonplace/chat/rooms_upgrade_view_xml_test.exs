defmodule Commonplace.Chat.RoomsUpgradeViewXmlTest do
  @moduledoc """
  CX-tb7s (sub-bead v of CX-04d8 M3): tests for the migration helper
  `Commonplace.Chat.Rooms.upgrade_view_xml/2` and the initial-write
  extension on `Chat.Rooms.create/3`.

  Anchor E from the M3 spec. Two responsibilities:

  * Existing pre-M3 chat rooms (with stale `_view.xml`) upgrade to the
    M3-shape via a single helper call. Idempotent.
  * New rooms ship with M3-shape `_view.xml` directly via `create/3`,
    populated by `ChatViewBuilder.build_view_xml/2` (no inline template
    duplication).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{ChatViewBuilder, Rooms}
  alias Commonplace.Document.{ContentType, ViewXml}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    # Restore to test-config default ("tmp/test_data") in on_exit — see
    # chat_view_compute_supervisor_test.exs for why captured-prior is
    # racy under parallel async:false execution.
    dir = Path.join(System.tmp_dir!(), "cp_rooms_upgrade_#{:rand.uniform(1_000_000_000)}")
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

  defp read_view_content(view_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, view_uuid)
    ContentType.get_content(doc) || ""
  end

  defp seed_pre_m3_view_xml(view_uuid) do
    # Pre-M3 shape — a hand-rolled stale template with kind="chat-room"
    # (hyphen) and no <arg> children. Simulates a room created before
    # M3 landed.
    stale = """
    <view schema="1">
      <entity kind="chat-room" name="general">
        <body>
          <text format="markdown">Old chat room.</text>
          <action name="post_message" label="Post"/>
          <action name="edit_message" label="Edit"/>
          <action name="delete_message" label="Delete"/>
        </body>
      </entity>
    </view>
    """

    # Overwrite the view doc with the stale shape via CommandRouter.write
    # (the same call site ViewCompute uses).
    {:ok, _} = Commonplace.CommandRouter.write(view_uuid, stale)
    :ok
  end

  describe "Chat.Rooms.create/3 — initial M3-shape view-XML" do
    test "new rooms ship with the ChatViewBuilder shape (kind='chat_room')",
         %{root: root} do
      {:ok, room} = Rooms.create(root, "fresh")

      content = read_view_content(room.view_uuid)
      assert {:ok, %ViewXml.Node{tag: :view}} = ViewXml.parse(content)

      assert content =~ ~s(kind="chat_room"),
             "new rooms must ship with chat_room (underscore), the M3 spec shape"

      # ChatViewBuilder always emits a <list id="messages"> — empty in this
      # fresh room, but present.
      assert content =~ ~s(<list id="messages">)

      # The action declarations have <arg> children — the substrate
      # ArgResolver path.
      assert content =~ ~s(from="../_messages")
      assert content =~ ~s(from="$session.presence_path")
    end

    test "fresh room's view-XML matches what ChatViewBuilder produces", %{root: root} do
      {:ok, room} = Rooms.create(root, "fresh")
      actual = read_view_content(room.view_uuid)
      expected = ChatViewBuilder.build_view_xml([], "fresh")

      assert actual == expected,
             "Chat.Rooms.create's initial _view.xml content must equal ChatViewBuilder.build_view_xml([], room_name)"
    end
  end

  describe "Chat.Rooms.upgrade_view_xml/2 — Anchor E" do
    test "pre-M3 stale view-XML upgrades to the M3 shape", %{root: root} do
      {:ok, room} = Rooms.create(root, "general")

      # Simulate a pre-M3 room: overwrite with stale view-XML.
      :ok = seed_pre_m3_view_xml(room.view_uuid)

      stale_content = read_view_content(room.view_uuid)
      assert stale_content =~ ~s(kind="chat-room"), "pre-condition: stale template seeded"

      # Run the migration.
      assert :ok = Rooms.upgrade_view_xml(root, "general")

      upgraded = read_view_content(room.view_uuid)

      assert upgraded =~ ~s(kind="chat_room"),
             "upgrade must rewrite kind to underscore form"

      assert upgraded =~ ~s(<list id="messages">)

      assert upgraded =~ ~s(from="../_messages"),
             "upgraded view-XML must carry <arg> children for ArgResolver"
    end

    test "upgrade preserves existing message materialization (round-trips)",
         %{root: root} do
      {:ok, room} = Rooms.create(root, "general")
      :ok = seed_pre_m3_view_xml(room.view_uuid)

      # Post a few messages BEFORE upgrade so the migration must materialize
      # them into the new view-XML body.
      {:ok, _} =
        Commonplace.Chat.Actions.post_message(room.messages_uuid, "first",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      {:ok, _} =
        Commonplace.Chat.Actions.post_message(room.messages_uuid, "second",
          room: "general",
          signer_id: "bob@bbbbbbbb",
          author_path: "bob.usr"
        )

      assert :ok = Rooms.upgrade_view_xml(root, "general")

      upgraded = read_view_content(room.view_uuid)

      assert upgraded =~ "first",
             "upgrade must materialize existing _messages into the new view-XML body"

      assert upgraded =~ "second"
      assert upgraded =~ "alice.usr"
      assert upgraded =~ "bob.usr"
    end

    test "idempotent: running twice produces the same view-XML (no-op second time)",
         %{root: root} do
      {:ok, _room} = Rooms.create(root, "general")

      # First upgrade (no-op since fresh rooms already match M3 shape, but
      # exercises the helper). Second upgrade must produce identical content.
      assert :ok = Rooms.upgrade_view_xml(root, "general")
      after_first = read_view_content(elem(Rooms.lookup(root, "general"), 1).view_uuid)

      assert :ok = Rooms.upgrade_view_xml(root, "general")
      after_second = read_view_content(elem(Rooms.lookup(root, "general"), 1).view_uuid)

      assert after_first == after_second, "upgrade must be idempotent"
    end

    test "returns {:error, :not_found} when the room doesn't exist", %{root: root} do
      assert {:error, :not_found} = Rooms.upgrade_view_xml(root, "no-such-room")
    end
  end
end
