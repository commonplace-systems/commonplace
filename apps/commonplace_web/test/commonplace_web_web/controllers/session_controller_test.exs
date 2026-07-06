defmodule CommonplaceWebWeb.SessionControllerTest do
  @moduledoc """
  CX-qat5.2 §2.2 + acceptance pin 3: `GET /login/:token` redeems an
  invite and binds the session; `GET /logout` clears it.
  """
  use CommonplaceWebWeb.ConnCase, async: false

  alias Commonplace.Invites
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_session_ctrl_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      File.rm_rf!(dir)
    end)

    %{root: root_uuid}
  end

  test "GET /login/:token with a valid invite binds the session and redirects to /wiki", %{
    conn: conn,
    root: root
  } do
    {:ok, %{identity_uuid: identity_uuid, token: token}} = Invites.mint("gwen", root)

    conn = get(conn, "/login/#{token}")

    assert redirected_to(conn, 302) == "/wiki"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged in as gwen"
    assert get_session(conn, :player_identity_uuid) == identity_uuid
    assert is_binary(get_session(conn, :session_nonce))
  end

  test "GET /login/:token twice with the same token: second attempt 403s (single-use)", %{
    conn: conn,
    root: root
  } do
    {:ok, %{token: token}} = Invites.mint("hank", root)

    conn1 = get(conn, "/login/#{token}")
    assert redirected_to(conn1, 302) == "/wiki"

    conn2 = get(build_conn(), "/login/#{token}")
    assert conn2.status == 403
    assert get_session(conn2, :player_identity_uuid) == nil
  end

  test "GET /login/:token with an expired token 403s and does not bind a session", %{
    conn: conn,
    root: root
  } do
    {:ok, %{token: token}} = Invites.mint("ivy", root, CommitStore, ttl_seconds: -1)

    conn = get(conn, "/login/#{token}")

    assert conn.status == 403
    assert get_session(conn, :player_identity_uuid) == nil
  end

  test "GET /login/:token with a bogus token 403s", %{conn: conn} do
    conn = get(conn, "/login/not-a-real-token")
    assert conn.status == 403
    assert get_session(conn, :player_identity_uuid) == nil
  end

  test "GET /logout clears the session and redirects to /wiki", %{conn: conn, root: root} do
    {:ok, %{token: token}} = Invites.mint("jill", root)
    conn = get(conn, "/login/#{token}")
    assert get_session(conn, :player_identity_uuid) != nil

    conn = get(conn, "/logout")

    assert redirected_to(conn, 302) == "/wiki"
    assert get_session(conn, :player_identity_uuid) == nil
    assert get_session(conn, :session_nonce) == nil
  end
end
