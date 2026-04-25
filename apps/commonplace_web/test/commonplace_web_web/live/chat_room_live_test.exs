defmodule CommonplaceWebWeb.ChatRoomLiveTest do
  @moduledoc """
  CX-71o3 (C1 of CX-p2qp): chat-room LiveView chrome.

  Tests cover the (β) pragmatic-LiveView path: mount loads + materializes
  messages, composer submit posts via Chat.Actions, live updates
  re-materialize on commit landing.

  Per chat-room.md (bb83a1b): roundtrip-only updates, no optimistic UI.
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Chat.{Actions, Rooms}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocCache, Schema}

  setup do
    # Mirror WikiLiveTest's pattern — point the production CommitStore
    # at a scratch dir, restart, seed root, restore on exit.
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    dir = Path.join(System.tmp_dir!(), "cp_chat_live_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    DocCache.clear()

    # Reset chat onramp state so each test starts clean (ETS index is
    # process-global; Application's OnrampSupervisor stays up).
    Commonplace.Chat.OnrampSupervisor.reset()

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, prior_data_dir)

      _ =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: prior_data_dir})

      File.rm_rf!(dir)
      DocCache.clear()
      Commonplace.Chat.OnrampSupervisor.reset()
    end)

    %{root: root_uuid}
  end

  describe "mount" do
    test "renders 'room not found' when /chat/:room doesn't exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat/never-created")
      assert html =~ "Chat room not found"
      assert html =~ "never-created"
    end

    test "renders an empty room (no messages yet) cleanly", %{conn: conn, root: root} do
      {:ok, _} = Rooms.create(root, "general")

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      assert html =~ "#general"
      assert html =~ "composer"
      # No messages list items.
      refute html =~ "message-"
    end

    test "renders existing messages with author + text", %{conn: conn, root: root} do
      {:ok, room} = Rooms.create(root, "general")

      {:ok, _} =
        Actions.post_message(room.messages_uuid, "hello world",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      assert html =~ "hello world"
      assert html =~ "alice.usr"
    end

    test "deleted messages render as [deleted]", %{conn: conn, root: root} do
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

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      assert html =~ "[deleted]"
      refute html =~ "secret"
    end

    test "edited messages render the latest text + (edited) marker",
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

      {:ok, _view, html} = live(conn, ~p"/chat/general")

      assert html =~ "v2-edited"
      assert html =~ "(edited)"
      refute html =~ "v1"
    end
  end

  describe "composer post_message" do
    test "submitting the composer appends a message and re-renders",
         %{conn: conn, root: root} do
      {:ok, _} = Rooms.create(root, "general")

      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Composer is a phx-submit form; render_submit triggers
      # handle_event("post_message", ...) and then we get the
      # commit-pubsub-driven re-render.
      view
      |> form("#composer", text: "live test message")
      |> render_submit()

      # Wait briefly for the commit pubsub to land + LiveView to
      # re-render. render(view) returns the latest server-rendered HTML.
      Process.sleep(150)
      html = render(view)

      assert html =~ "live test message"
    end

    test "empty submit is a no-op (no commit, no re-render)",
         %{conn: conn, root: root} do
      {:ok, _} = Rooms.create(root, "general")
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      view
      |> form("#composer", text: "")
      |> render_submit()

      Process.sleep(50)
      html = render(view)
      refute html =~ "message-"
    end
  end

  describe "live updates from concurrent posts" do
    test "an external post lands in the open view via PubSub",
         %{conn: conn, root: root} do
      {:ok, room} = Rooms.create(root, "general")
      {:ok, view, _html} = live(conn, ~p"/chat/general")

      # Simulate another tab / agent posting via the action layer.
      {:ok, _} =
        Actions.post_message(room.messages_uuid, "from another peer",
          room: "general",
          signer_id: "bob@bbbbbbbb",
          author_path: "bob.usr"
        )

      Process.sleep(150)
      html = render(view)

      assert html =~ "from another peer"
      assert html =~ "bob.usr"
    end
  end
end
