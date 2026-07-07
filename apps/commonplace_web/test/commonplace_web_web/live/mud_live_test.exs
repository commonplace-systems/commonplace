defmodule CommonplaceWebWeb.MudLiveTest do
  @moduledoc """
  CX-gjpi: `MudLive` mounted anonymously (no session — `SessionIdentity.
  resolve/1` collapses to `:anonymous`) must show the login-required
  message and never start a `PlayerSession`. The router's own
  `:authenticated` `live_session` gate (`RequireAuth`) already blocks an
  anonymous request from ever reaching this LiveView in production;
  `live_isolated/3` here mounts the LiveView directly, bypassing that
  router gate, so this test exercises `MudLive.mount/3`'s own
  defense-in-depth `:anonymous` branch in isolation.

  CX-i9j3 (UI Inc-1 increment 3): the authed suite below pins the
  `SessionView` integration — the transcript now renders FROM a
  committed view-doc (`SessionView.to_html`-shaped turns, walked
  directly and escaped through `~H`) rather than a transient
  `@scrollback` assign list. Covers: own-turn rendering, ambient
  coalescing (M events -> 1 rendered ambient turn), ordering (ambient
  before a command must render before that command's turn), and the
  XSS-escaping gate (`Yelixer.Types.XMLElement.to_string/2` does NOT
  escape, so `MudLive` must never `Phoenix.HTML.raw/1` it — this test
  proves player input renders escaped).
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Invites
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias CommonplaceWebWeb.MudLive

  test "anonymous mount shows the login-required message, no session started", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, MudLive, session: %{})

    assert html =~ "You must be logged in to play"
    assert render(view) =~ "You must be logged in to play"
    refute has_element?(view, "form[phx-submit=command]")
  end

  describe "authenticated session (CX-i9j3 SessionView integration)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_mud_live_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      Application.put_env(:commonplace, :data_dir, dir)

      sup = Commonplace.Store.CommitStoreSupervisor
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

      Commonplace.Tree.DocCache.clear()

      # Seed the workspace root schema + root pointer file, and a "mud"
      # dir under it (a bare Schema doc is enough — Citizenship.ensure
      # provisions players/<name>/ under it on demand; the world's
      # shared "start" room is optional and simply absent here).
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)
      File.write!(Path.join(dir, "root"), root_uuid)

      mud_uuid = UUID.uuid4()
      mud_doc = Schema.new_schema()
      CommitStore.create_commit(Commonplace.Store.CommitStore, mud_uuid, Yelixer.Encoding.encode_update(mud_doc), nil)

      root_doc2 = Schema.add_directory(root_doc, "mud", mud_uuid)
      CommitStore.create_chained_commit(
        Commonplace.Store.CommitStore,
        root_uuid,
        Yelixer.Encoding.encode_update(root_doc2),
        %{}
      )

      on_exit(fn ->
        _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
        _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

        Application.put_env(:commonplace, :data_dir, "tmp/test_data")

        {:ok, _pid} =
          Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

        File.rm_rf!(dir)
        Commonplace.Tree.DocCache.clear()
      end)

      {conn, _identity_uuid, _nonce} = login_conn(Phoenix.ConnTest.build_conn(), root_uuid)

      %{conn: conn}
    end

    test "submitting a command renders a command turn with cmd + output visible", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, MudLive, session: get_session(conn))

      view
      |> form("form[phx-submit=command]", %{"line" => "look"})
      |> render_submit()

      html = render(view)
      assert html =~ ~s(class="turn command")
      assert html =~ ~s(class="cmd")
      assert html =~ "look"
    end

    test "ambient events since the last tick coalesce into ONE ambient turn", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, MudLive, session: get_session(conn))

      pid = :sys.get_state(view.pid).socket.assigns.session_pid

      # `{:buffer_append, line}` is the exact cast PlayerSession's own
      # buffered-mode render_fn closure uses for every real ambient event
      # (see `handle_cast({:buffer_append, line}, ...)` in
      # `player_session.ex`) — casting it directly here simulates two
      # ambient events landing in the underlying session before the next
      # `:tick` poll, without needing a second NPC/player in the room.
      GenServer.cast(pid, {:buffer_append, "Grunk waves."})
      GenServer.cast(pid, {:buffer_append, "A bell tolls."})

      # This poll IS the debounce window: MudLive's handle_info(:tick)
      # drains both lines and routes them through the coalescing buffer
      # in one shot (buffer_add x2 -> ONE buffer_flush).
      send(view.pid, :tick)
      html = render(view)

      assert length(Regex.scan(~r/class="turn ambient"/, html)) == 1
      assert html =~ "Grunk waves."
      assert html =~ "A bell tolls."
    end

    test "ambient that arrived before a command renders BEFORE that command's turn", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, MudLive, session: get_session(conn))

      pid = :sys.get_state(view.pid).socket.assigns.session_pid
      GenServer.cast(pid, {:buffer_append, "A distant bell tolls."})
      send(view.pid, :tick)

      # A distinctive command text (mount's own spawn-greet already lands
      # a "look" command turn — see `handle_info(:enter, ...)` — so this
      # test's OWN submitted command must be uniquely findable in the
      # rendered HTML, not confused with that earlier greet turn).
      view
      |> form("form[phx-submit=command]", %{"line" => "inventory"})
      |> render_submit()

      html = render(view)
      ambient_at = :binary.match(html, "A distant bell tolls.") |> elem(0)
      command_at = :binary.match(html, ~s(class="cmd">inventory)) |> elem(0)

      assert ambient_at < command_at,
             "ambient turn must render before the subsequent command's turn"
    end

    test "an XSS payload in a command renders escaped, not as a live tag", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, MudLive, session: get_session(conn))

      payload = "<script>alert(1)</script>"

      view
      |> form("form[phx-submit=command]", %{"line" => payload})
      |> render_submit()

      html = render(view)
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert(1)</script>"
    end
  end

  defp login_conn(conn, root) do
    {:ok, %{identity_uuid: identity_uuid, token: token}} =
      Invites.mint("mud-live-#{System.unique_integer([:positive])}", root)

    {:ok, ^identity_uuid} = Invites.redeem(token)
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:player_identity_uuid, identity_uuid)
      |> Plug.Conn.put_session(:session_nonce, nonce)

    {conn, identity_uuid, nonce}
  end
end
