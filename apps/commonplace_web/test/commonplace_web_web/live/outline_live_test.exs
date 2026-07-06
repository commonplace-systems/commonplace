defmodule CommonplaceWebWeb.OutlineLiveTest do
  @moduledoc """
  CX-k8tn: OutlineLive — render the reconstructed tree, mutate via
  events (the keybind path), and re-render live on commits from OTHER
  writers (the PubSub loop).
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Outline
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_outline_live_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    root_uuid = UUID.uuid4()
    CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      File.rm_rf!(dir)
    end)

    {:ok, uuid} = Outline.create("daily", root_uuid, CommitStore)
    {:ok, a} = Outline.add_item(CommitStore, uuid, %{text: "Top task"})
    {:ok, b} = Outline.add_item(CommitStore, uuid, %{text: "Sub task", parent: a})

    %{uuid: uuid, a: a, b: b}
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
end
