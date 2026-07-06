defmodule CommonplaceWebWeb.TreeLiveTest do
  @moduledoc """
  CX-nn4y: TreeLive's `yjs_edit` save path threads the mount-resolved
  session identity's `signing_context` into the commit. There is no
  reconstruction-client_id seam here (see the moduledoc), so these
  tests pin the signing behavior only — logged-in writes land signed
  as the player, anonymous writes are unchanged (unsigned).
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

    %{root: root_uuid, page_uuid: page_uuid}
  end

  describe "logged-in session identity (CX-nn4y, following CX-qat5.2's ChatRoomLive pattern)" do
    defp login_conn(conn, root) do
      {:ok, %{identity_uuid: identity_uuid, token: token}} = Invites.mint("mallory", root)
      {:ok, ^identity_uuid} = Invites.redeem(token)
      nonce = Base.encode64(:crypto.strong_rand_bytes(16))

      conn =
        conn
        |> init_test_session(%{})
        |> Plug.Conn.put_session(:player_identity_uuid, identity_uuid)
        |> Plug.Conn.put_session(:session_nonce, nonce)

      {conn, identity_uuid, nonce}
    end

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

    test "anonymous yjs_edit save behaves exactly as before (unsigned)",
         %{conn: conn, page_uuid: page_uuid} do
      {:ok, view, _html} = live(conn, ~p"/tree")

      view |> element("button[phx-value-name='note.md']") |> render_click()

      encoded = browser_edit_update(page_uuid, "hello world")
      render_hook(view, "yjs_edit", %{"update" => encoded})

      {:ok, commit} = CommitStore.latest_commit(Commonplace.Store.CommitStore, page_uuid)
      assert commit.signer_id == nil
      assert commit.signature == nil
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
