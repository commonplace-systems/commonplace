defmodule Commonplace.Presence.ReaperTest do
  use ExUnit.Case

  alias Commonplace.Presence
  alias Commonplace.Presence.Reaper
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_reaper_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_reaper_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{root: root_uuid, store: store_name, dir: dir}
  end

  test "find_stale returns nothing when no presence entries exist", %{root: root, store: store} do
    stale = Reaper.find_stale(root, store)
    assert stale == []
  end

  test "find_stale detects stale presence", %{root: root, store: store} do
    {:ok, _uuid} = Presence.create("old-proc", :exe, root, store)

    root_doc = load_schema(root, store)
    {:ok, entry} = Schema.get_entry(root_doc, "old-proc.exe")

    old_time = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    doc = load_doc(entry.node_id, store)
    doc = Commonplace.Document.ContentType.set_key(doc, "heartbeat", old_time)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, entry.node_id, update, nil)

    stale = Reaper.find_stale(root, store, 30_000)
    assert length(stale) == 1
    assert hd(stale).name == "old-proc.exe"
  end

  test "find_stale ignores fresh presence", %{root: root, store: store} do
    {:ok, _uuid} = Presence.create("fresh-proc", :exe, root, store)
    stale = Reaper.find_stale(root, store, 30_000)
    assert stale == []
  end

  test "reap removes stale entries", %{root: root, store: store} do
    {:ok, _uuid} = Presence.create("dead-proc", :exe, root, store)

    root_doc = load_schema(root, store)
    {:ok, entry} = Schema.get_entry(root_doc, "dead-proc.exe")

    old_time = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    doc = load_doc(entry.node_id, store)
    doc = Commonplace.Document.ContentType.set_key(doc, "heartbeat", old_time)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, entry.node_id, update, nil)

    removed = Reaper.reap(root, store, 30_000)
    assert removed == ["dead-proc.exe"]

    root_doc = load_schema(root, store)
    assert :error = Schema.get_entry(root_doc, "dead-proc.exe")
  end

  test "GenServer periodically scans", %{root: root, store: store} do
    {:ok, reaper} = Reaper.start_link(
      root_uuid: root,
      store: store,
      interval: 100,
      stale_threshold: 30_000
    )

    Process.sleep(250)
    assert Process.alive?(reaper)
    GenServer.stop(reaper)
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Commonplace.Tree.Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc
      :none ->
        Commonplace.Tree.Schema.new_schema()
    end
  end

  defp load_doc(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc
      :none ->
        Yelixer.Doc.new()
    end
  end
end
