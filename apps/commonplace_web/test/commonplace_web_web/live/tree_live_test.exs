defmodule CommonplaceWebWeb.TreeLiveTest do
  @moduledoc """
  CX-nn4y: TreeLive's `yjs_edit` save path threads the mount-resolved
  session identity's `signing_context` into the commit. There is no
  reconstruction-client_id seam here (see the moduledoc), so these
  tests pin the signing behavior only — logged-in writes land signed
  as the player.

  CX-f89w: `/tree` is now gated (read-auth) — anonymous mounts redirect
  to `/` rather than reaching the LiveView, so `conn` here is
  authenticated by default (see `setup`). The former "anonymous yjs_edit
  save behaves exactly as before (unsigned)" pin is superseded: an
  anonymous conn can no longer reach `/tree` at all, so that scenario
  moved to the read-auth gate suite (`test/commonplace_web_web/read_auth_test.exs`).
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Document.ContentType
  alias Commonplace.Invites
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocCache, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_tree_live_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    DocCache.clear()

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    # A text page under the root schema, so "select" + "yjs_edit" have
    # something to load and save.
    page_uuid = UUID.uuid4()
    page_doc = Yelixer.Doc.new()
    page_doc = ContentType.create(page_doc, :text, "note.md")
    page_doc = ContentType.insert_text(page_doc, 0, "hello")
    CommitStoreClient.create_commit(page_uuid, Yelixer.Encoding.encode_update(page_doc), nil)

    schema = Schema.add_file(root_doc, "note.md", page_uuid)
    CommitStoreClient.create_chained_commit(root_uuid, Yelixer.Encoding.encode_update(schema))

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      File.rm_rf!(dir)
      DocCache.clear()
    end)

    # CX-f89w: /tree is gated — default `conn` in this module is a
    # logged-in session so existing (pre-read-auth) test bodies keep
    # working unmodified. Tests that need a SPECIFIC identity (to check
    # signer_id) call `login_conn/2` themselves, which fully replaces
    # the session via `init_test_session/2`.
    {conn, _identity_uuid, _nonce} = login_conn(Phoenix.ConnTest.build_conn(), root_uuid)

    %{conn: conn, root: root_uuid, page_uuid: page_uuid}
  end

  defp login_conn(conn, root) do
    {:ok, %{identity_uuid: identity_uuid, token: token}} =
      Invites.mint("mallory-#{System.unique_integer([:positive])}", root)

    {:ok, ^identity_uuid} = Invites.redeem(token)
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))

    conn =
      conn
      |> init_test_session(%{})
      |> Plug.Conn.put_session(:player_identity_uuid, identity_uuid)
      |> Plug.Conn.put_session(:session_nonce, nonce)

    {conn, identity_uuid, nonce}
  end

  describe "logged-in session identity (CX-nn4y, following CX-qat5.2's ChatRoomLive pattern)" do
    test "a logged-in session's yjs_edit save lands signed as that player",
         %{conn: conn, root: root_uuid, page_uuid: page_uuid} do
      {conn, identity_uuid, _nonce} = login_conn(conn, root_uuid)

      {:ok, ctx} = Commonplace.Crypto.AgentKeys.signing_context(identity_uuid)
      expected_signer_id = Commonplace.Crypto.Signing.signer_id(identity_uuid, ctx.public_key)

      {:ok, view, _html} = live(conn, ~p"/tree")

      view |> element("button[phx-value-name='note.md']") |> render_click()

      encoded = browser_edit_update(page_uuid, "hello world")
      render_hook(view, "yjs_edit", %{"update" => encoded})

      {:ok, commit} = CommitStore.latest_commit(Commonplace.Store.CommitStore, page_uuid)
      assert commit.signer_id == expected_signer_id
      assert commit.signature != nil
    end

    # CX-f89w: /tree is now gated — an anonymous conn can no longer
    # mount TreeLive at all (superseding the old "anonymous yjs_edit
    # save behaves exactly as before (unsigned)" pin). See the gate
    # regression coverage in read_auth_test.exs.
    test "anonymous conn is redirected before it can reach yjs_edit at all",
         %{page_uuid: page_uuid} do
      anon_conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: "/"}}} = live(anon_conn, ~p"/tree")

      assert {:ok, commit} = CommitStore.latest_commit(Commonplace.Store.CommitStore, page_uuid)
      # No yjs_edit landed — the page doc is still at its seeded commit.
      assert commit.signer_id == nil
    end
  end

  # Simulates the browser's Y.Doc: reconstructs the page under a
  # distinct "browser" client_id, edits it, and full-state-encodes the
  # result (mirroring the YjsHook's `Y.encodeStateAsUpdate(this.ydoc)`
  # resync-on-edit behavior) — base64'd, ready for a "yjs_edit" event.
  defp browser_edit_update(page_uuid, new_text) do
    {:ok, doc} =
      Commonplace.Tree.DocBuilder.reconstruct_doc(CommitStoreClient, page_uuid,
        client_id: 999_888_777
      )

    doc = ContentType.insert_text(doc, 5, " " <> String.slice(new_text, 6..-1//1))
    Base.encode64(Yelixer.Encoding.encode_update(doc))
  end
end
