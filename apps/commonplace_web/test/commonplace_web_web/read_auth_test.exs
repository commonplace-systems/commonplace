defmodule CommonplaceWebWeb.ReadAuthTest do
  @moduledoc """
  CX-f89w: require an authenticated session to VIEW wiki/tree/chat/
  outline. Pins the read-auth spec's acceptance list
  (docs/plans/2026-07-06-read-auth-spec.md §6):

    1. Anonymous GET on a gated route → 302 to `/`, no content.
    2. Anonymous LiveView socket connect to a gated route → halted/
       redirected (this is the SAME check as #1 via `live/2` — a dead
       GET and a test `live/2` call both exercise the initial HTTP
       connect that Phoenix.LiveViewTest drives; the plug fires first).
    3. A logged-in session reaches gated content (200, content present).
    4. `GET /` → 200 public landing, no gated content, works logged-out.
    5. `/login/:token` and `/logout` stay reachable logged-out.
    6. `/federation` is unaffected by read-auth (still 403 without a
       bearer token) — a regression guard that read-auth didn't bleed
       into the separate bearer-token pipeline.

  Per-LiveView functional coverage (rendering, mutations, signing) lives
  in each LiveView's own test file; those now default `conn` to a
  logged-in session (see their `setup` blocks) and carry a one-off gate
  regression test each. This file is the cross-cutting gate contract.
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Invites
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_read_auth_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(CommitStore, root_uuid, update, nil)
    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir, store: CommitStore)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      File.rm_rf!(dir)
      Commonplace.Tree.DocCache.clear()
    end)

    %{root: root_uuid}
  end

  defp login_conn(conn, root) do
    {:ok, %{identity_uuid: identity_uuid, token: token}} =
      Invites.mint("gate-check-#{System.unique_integer([:positive])}", root)

    {:ok, ^identity_uuid} = Invites.redeem(token)
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))

    conn
    |> init_test_session(%{})
    |> Plug.Conn.put_session(:player_identity_uuid, identity_uuid)
    |> Plug.Conn.put_session(:session_nonce, nonce)
  end

  describe "anonymous dead-render GET on gated routes (pin 1)" do
    test "GET /wiki → 302 to /, no content", %{conn: conn} do
      conn = get(conn, ~p"/wiki")
      assert redirected_to(conn, 302) == "/"
      refute conn.resp_body =~ "New Page"
    end

    test "GET /tree → 302 to /, no content", %{conn: conn} do
      conn = get(conn, ~p"/tree")
      assert redirected_to(conn, 302) == "/"
    end

    test "GET /chat/:room → 302 to /, no content", %{conn: conn} do
      conn = get(conn, ~p"/chat/general")
      assert redirected_to(conn, 302) == "/"
    end

    test "GET /outline/:name → 302 to /, no content", %{conn: conn} do
      conn = get(conn, ~p"/outline/daily")
      assert redirected_to(conn, 302) == "/"
    end
  end

  describe "anonymous LiveView socket connect to gated routes (pin 2)" do
    test "live/2 on /wiki halts/redirects to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/wiki")
    end

    test "live/2 on /tree halts/redirects to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/tree")
    end

    test "live/2 on /chat/:room halts/redirects to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/chat/general")
    end

    test "live/2 on /outline/:name halts/redirects to /", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/outline/daily")
    end
  end

  describe "logged-in session reaches gated content (pin 3)" do
    test "GET /wiki renders 200 with content for a logged-in session", %{
      conn: conn,
      root: root
    } do
      conn = login_conn(conn, root)

      {:ok, _view, html} = live(conn, ~p"/wiki")

      assert html =~ "New Page"
    end
  end

  describe "GET / is the public login landing (pin 4)" do
    test "renders 200 for an anonymous visitor, no gated content", %{conn: conn} do
      conn = get(conn, ~p"/")

      html = html_response(conn, 200)
      assert html =~ "This workspace is private"
      refute html =~ "New Page"
    end
  end

  describe "auth endpoints stay reachable logged-out (pin 5)" do
    test "GET /login/:token with a valid invite is reachable anonymously", %{
      conn: conn,
      root: root
    } do
      {:ok, %{token: token}} = Invites.mint("dana", root)

      conn = get(conn, "/login/#{token}")

      assert redirected_to(conn, 302) == "/wiki"
    end

    test "GET /logout is reachable anonymously", %{conn: conn} do
      conn = get(conn, ~p"/logout")
      assert redirected_to(conn, 302) == "/wiki"
    end
  end

  describe "/federation is unaffected by read-auth (pin 6)" do
    test "GET /federation/docs/:uuid/cids 403s without a bearer token", %{conn: conn} do
      conn = get(conn, "/federation/docs/#{UUID.uuid4()}/cids")
      assert conn.status == 403
    end
  end
end
