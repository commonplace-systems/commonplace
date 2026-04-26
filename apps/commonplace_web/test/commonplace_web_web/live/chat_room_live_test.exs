defmodule CommonplaceWebWeb.ChatRoomLiveTest do
  @moduledoc """
  CX-71o3 / CX-lok1 (M3 sub-bead iv): chat-room LiveView is now a thin
  wrapper around `CommonplaceWebWeb.ViewRenderer`. Most rendering
  behavior is exercised by ViewRenderer unit tests + the Wallaby chat
  feature tests; these unit tests cover the LiveView-specific
  responsibilities:

  * Lookup + not-found handling (chat-tier branding stays here)
  * ChatViewCompute lazy-start on mount
  * Async re-render via the commits PubSub topic on the view doc
  * Action dispatch via the unified phx-submit FORM path

  Per the M3 spec architectural anchor (views.md): view-XML IS the
  rendered semantic output. ChatRoomLive doesn't own a HEEX template
  for the chat shape any more — it loads view-XML, hands it to the
  generic renderer, and routes user interactions through the
  substrate ArgResolver + dispatcher.
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Chat.{Actions, ChatViewComputeSupervisor, Rooms}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocCache, Schema}

  # ViewCompute writes view-XML asynchronously after init + on each
  # source commit. Tests rely on a small wait after triggering events.
  @recompute_wait_ms 200

  setup do
    # Restore to test-config default ("tmp/test_data") in on_exit —
    # captured-prior is racy under parallel async:false execution.
    dir = Path.join(System.tmp_dir!(), "cp_chat_live_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    DocCache.clear()
    Commonplace.Chat.OnrampSupervisor.reset()
    ChatViewComputeSupervisor.reset()

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      File.rm_rf!(dir)
      DocCache.clear()
      Commonplace.Chat.OnrampSupervisor.reset()
      ChatViewComputeSupervisor.reset()
    end)

    %{root: root_uuid}
  end

  describe "mount — lookup + not-found" do
    test "renders 'room not found' when /chat/:room doesn't exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat/never-created")
      assert html =~ "Chat room not found"
      assert html =~ "never-created"
    end

    test "renders the chat-room entity even with no messages", %{conn: conn, root: root} do
      {:ok, _} = Rooms.create(root, "general")

      {:ok, view, _html} = live(conn, ~p"/chat/general")
      Process.sleep(@recompute_wait_ms)
      html = render(view)

      assert html =~ "entity--chat_room"
      assert html =~ "general"
      # phx-submit FORM emission for post_message is the chat composer now
      assert html =~ ~s(phx-value-action="post_message")
    end
  end

  describe "messages render via the generic renderer (ChatViewCompute path)" do
    test "existing messages surface with author + text", %{conn: conn, root: root} do
      {:ok, room} = Rooms.create(root, "general")

      {:ok, _} =
        Actions.post_message(room.messages_uuid, "hello world",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      {:ok, view, _html} = live(conn, ~p"/chat/general")
      Process.sleep(@recompute_wait_ms)
      html = render(view)

      assert html =~ "hello world"
      assert html =~ "alice.usr"
      assert html =~ "entity--message"
    end

    test "deleted messages render as [deleted] (chain semantics through ChatViewBuilder)",
         %{conn: conn, root: root} do
      {:ok, room} = Rooms.create(root, "general")

      {:ok, %{message_id: m1}} =
        Actions.post_message(room.messages_uuid, "secret",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      {:ok, _} =
        Actions.delete_message(room.messages_uuid, m1,
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      {:ok, view, _html} = live(conn, ~p"/chat/general")
      Process.sleep(@recompute_wait_ms)
      html = render(view)

      assert html =~ "[deleted]"
      refute html =~ "secret"
    end

    test "edited messages render the latest text + edited=true field",
         %{conn: conn, root: root} do
      {:ok, room} = Rooms.create(root, "general")

      {:ok, %{message_id: m1}} =
        Actions.post_message(room.messages_uuid, "v1",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      {:ok, _} =
        Actions.edit_message(room.messages_uuid, m1, "v2-edited",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      {:ok, view, _html} = live(conn, ~p"/chat/general")
      Process.sleep(@recompute_wait_ms)
      html = render(view)

      assert html =~ "v2-edited"
      # ViewRenderer renders <field name="edited" value="true"/> as
      # <dt>edited:</dt><dd>true</dd>. Check both pieces appear adjacent.
      assert html =~ ~r/edited:.+true/,
             "edited=true field should appear in rendered output"

      refute html =~ "v1"
    end
  end

  describe "live updates from concurrent posts" do
    test "an external post lands in the open view via PubSub",
         %{conn: conn, root: root} do
      {:ok, room} = Rooms.create(root, "general")
      {:ok, view, _html} = live(conn, ~p"/chat/general")
      Process.sleep(@recompute_wait_ms)

      {:ok, _} =
        Actions.post_message(room.messages_uuid, "from another peer",
          room: "general",
          signer_id: "bob@bbbbbbbb",
          author_path: "bob.usr"
        )

      Process.sleep(@recompute_wait_ms)
      html = render(view)

      assert html =~ "from another peer"
      assert html =~ "bob.usr"
    end
  end
end
