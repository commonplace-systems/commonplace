defmodule CommonplaceWebWeb.OutlineLiveTest do
  @moduledoc """
  CX-k8tn: OutlineLive — render the reconstructed tree, mutate via
  events (the keybind path), and re-render live on commits from OTHER
  writers (the PubSub loop).

  CX-f89w: `/outline/:name` is now gated (read-auth) — anonymous mounts
  redirect to `/` rather than reaching the LiveView, so `conn` here is
  authenticated by default (see `setup`). The former "anonymous session
  write behaves exactly as before (unsigned, funnel hand)" pin is
  superseded: an anonymous conn can no longer reach `/outline/:name` at
  all, so that scenario moved to the read-auth gate suite
  (`test/commonplace_web_web/read_auth_test.exs`).
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Invites
  alias Commonplace.Outline
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_outline_live_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    :ok = Commonplace.Trust.AuditDispatcher.flush()
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    root_uuid = UUID.uuid4()

    CommitStore.create_commit(
      CommitStore,
      root_uuid,
      Yelixer.Encoding.encode_update(Schema.new_schema()),
      nil
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      :ok = Commonplace.Trust.AuditDispatcher.flush()
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      restored_data_dir = prior_data_dir || "tmp/test_data"
      Application.put_env(:commonplace, :data_dir, restored_data_dir)
      File.rm_rf!(dir)

      {:ok, restored_pid} =
        Supervisor.start_child(sup, {CommitStore, data_dir: restored_data_dir})

      assert Process.alive?(restored_pid)
      assert Process.whereis(CommitStore) == restored_pid

      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.join(restored_data_dir, "commits")
    end)

    {:ok, uuid} = Outline.create("daily", root_uuid, CommitStore)
    {:ok, a} = Outline.add_item(CommitStore, uuid, %{text: "Top task"})
    {:ok, b} = Outline.add_item(CommitStore, uuid, %{text: "Sub task", parent: a})

    # CX-f89w: /outline/:name is gated — default `conn` in this module
    # is a logged-in session so existing (pre-read-auth) test bodies
    # keep working unmodified. Tests that need a SPECIFIC identity (to
    # check signer_id) call `login_conn/2` themselves, which fully
    # replaces the session via `init_test_session/2`.
    {conn, _identity_uuid, _nonce} = login_conn(Phoenix.ConnTest.build_conn(), root_uuid)

    %{conn: conn, uuid: uuid, a: a, b: b, root: root_uuid}
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

  test "renders the nested tree", %{conn: conn, a: a, b: b} do
    {:ok, view, html} = live(conn, ~p"/outline/daily")

    assert html =~ "Top task"
    assert html =~ "Sub task"
    # b renders nested under a (a's <li> contains b's).
    assert has_element?(view, "li[data-item-id=\"#{a}\"] li[data-item-id=\"#{b}\"]")
  end

  test "unknown outline → not found", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/outline/nope")
    assert html =~ "No outline named"
  end

  test "indent event reparents via the mutation layer", %{conn: conn, uuid: uuid, a: a} do
    {:ok, c} = Outline.add_item(CommitStore, uuid, %{text: "Becomes child", after: a})

    {:ok, view, _} = live(conn, ~p"/outline/daily")
    view |> element("li[data-item-id=\"#{c}\"] button[title=\"indent\"]") |> render_click()

    by_id = Map.new(Outline.items(CommitStore, uuid), &{&1.id, &1})
    assert by_id[c].parent == a
    assert has_element?(view, "li[data-item-id=\"#{a}\"] li[data-item-id=\"#{c}\"]")
  end

  test "Enter keydown creates a sibling", %{conn: conn, uuid: uuid, b: b} do
    {:ok, view, _} = live(conn, ~p"/outline/daily")

    view
    |> element("li[data-item-id=\"#{b}\"] input.bullet-input")
    |> render_keydown(%{"key" => "Enter", "id" => b})

    items = Outline.items(CommitStore, uuid)
    assert length(items) == 3
    new_item = Enum.find(items, &(&1.text == ""))
    assert new_item.parent == Enum.find(items, &(&1.id == b)).parent
  end

  test "set_text on blur edits the bullet", %{conn: conn, uuid: uuid, b: b} do
    {:ok, view, _} = live(conn, ~p"/outline/daily")

    view
    |> element("li[data-item-id=\"#{b}\"] input.bullet-input")
    |> render_blur(%{"id" => b, "value" => "Sub task (edited)"})

    assert Enum.find(Outline.items(CommitStore, uuid), &(&1.id == b)).text == "Sub task (edited)"
    assert render(view) =~ "Sub task (edited)"
  end

  test "a commit from ANOTHER writer re-renders live", %{conn: conn, uuid: uuid} do
    {:ok, view, html} = live(conn, ~p"/outline/daily")
    refute html =~ "From elsewhere"

    # Another writer (e.g. an MCP agent) mutates the doc directly.
    {:ok, _} = Outline.add_item(CommitStore, uuid, %{text: "From elsewhere"})

    # The commit broadcast drives the re-render.
    assert render_async(view) =~ "From elsewhere" or render(view) =~ "From elsewhere"
  end

  describe "write rate limiting (CX-qat5.6)" do
    alias CommonplaceWebWeb.WriteRateLimit

    setup do
      :ok = WriteRateLimit.config(max_writes: 2, window_ms: 60_000)

      on_exit(fn ->
        # Restore defaults so other test modules aren't affected by this
        # singleton GenServer's config.
        :ok = WriteRateLimit.config(max_writes: 30, window_ms: 10_000)
      end)

      :ok
    end

    test "the (N+1)th write is rejected without creating a commit, earlier ones succeed",
         %{conn: conn, uuid: uuid} do
      {:ok, view, _} = live(conn, ~p"/outline/daily")

      # Each render_click on the same connected view runs handle_event in
      # the same LiveView process, so all three share one connection key.
      view |> element("button", "+ item") |> render_click()
      view |> element("button", "+ item") |> render_click()

      items_after_two = Outline.items(CommitStore, uuid)
      # 2 seeded (a, b) + 2 successful new_item writes.
      assert length(items_after_two) == 4

      html = view |> element("button", "+ item") |> render_click()

      items_after_three = Outline.items(CommitStore, uuid)
      # The 3rd write must NOT have created a commit.
      assert length(items_after_three) == 4
      assert html =~ "Too many edits"
    end
  end

  describe "logged-in session identity (CX-nn4y, following CX-qat5.2's ChatRoomLive pattern)" do
    test "a logged-in session's new_item write is signed as that player and mints under the session hand",
         %{conn: conn, root: root_uuid, uuid: uuid} do
      {conn, identity_uuid, nonce} = login_conn(conn, root_uuid)

      {:ok, ctx} = Commonplace.Crypto.AgentKeys.signing_context(identity_uuid)
      expected_signer_id = Commonplace.Crypto.Signing.signer_id(identity_uuid, ctx.public_key)
      expected_hand = Commonplace.WriterHand.for_session(ctx.public_key, nonce)

      # Setup already seeded two items via the funnel hand
      # (`WriterHand.for_doc/1`) with no identity — capture its clock
      # before the session write so we can prove the session write did
      # NOT land under it.
      funnel_hand = Commonplace.WriterHand.for_doc(uuid)
      {:ok, doc_before} = DocBuilder.reconstruct_doc(CommitStore, uuid)

      funnel_clock_before =
        Yelixer.StateVector.get(Yelixer.BlockStore.state_vector(doc_before.store), funnel_hand)

      {:ok, view, _html} = live(conn, ~p"/outline/daily")

      view |> element("button", "+ item") |> render_click()

      # Acceptance: the landed commit is signed as the player.
      {:ok, commit} = CommitStore.latest_commit(CommitStore, uuid)
      assert commit.signer_id == expected_signer_id
      assert commit.signature != nil

      # Acceptance: the mutation minted under the session's stable hand,
      # not the shared `WriterHand.for_doc/1` funnel hand — the whole
      # point of CX-nn4y closing the residual-collision hazard.
      {:ok, doc} = DocBuilder.reconstruct_doc(CommitStore, uuid)
      sv = Yelixer.BlockStore.state_vector(doc.store)
      assert Map.has_key?(sv.clocks, expected_hand)
      # The funnel hand's clock is unchanged — the session write did not
      # mint under it.
      assert Yelixer.StateVector.get(sv, funnel_hand) == funnel_clock_before
    end

    # CX-f89w: /outline/:name is now gated — an anonymous conn can no
    # longer mount OutlineLive at all (superseding the old "anonymous
    # session write behaves exactly as before (unsigned, funnel hand)"
    # pin). See the gate regression coverage in read_auth_test.exs.
    test "anonymous conn is redirected before it can reach the new_item write at all",
         %{uuid: uuid} do
      anon_conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: "/"}}} = live(anon_conn, ~p"/outline/daily")

      # Still just the 2 seeded items — no anonymous write landed.
      assert length(Outline.items(CommitStore, uuid)) == 2
    end
  end
end
