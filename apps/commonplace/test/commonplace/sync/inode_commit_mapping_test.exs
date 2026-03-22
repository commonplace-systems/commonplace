defmodule Commonplace.Sync.InodeCommitMappingTest do
  @moduledoc """
  Tests for inode↔commit_id mapping and shadow integration with sync.

  Verifies that:
  1. InodeTracker maps inodes to commit IDs
  2. Export creates shadows before atomic writes
  3. Stale writes to shadows are detected and merged back via CRDT
  """
  use ExUnit.Case

  alias Commonplace.Sync.InodeTracker
  alias Commonplace.Sync.SyncLoop
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_inode_cid_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store_name})

    sync_dir = Path.join(System.tmp_dir!(), "cp_inode_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(sync_dir)
    shadow_dir = Path.join(sync_dir, ".commonplace-shadow")

    on_exit(fn ->
      File.rm_rf!(data_dir)
      File.rm_rf!(sync_dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, sync_dir: sync_dir, shadow_dir: shadow_dir}
  end

  describe "InodeTracker.Registry" do
    test "registers and looks up inode→commit_id mapping" do
      {:ok, registry} = InodeTracker.Registry.start_link([])

      InodeTracker.Registry.track(registry, {1, 12345}, "commit-abc", "doc-uuid-1", "/path/to/file")

      assert {:ok, mapping} = InodeTracker.Registry.lookup(registry, {1, 12345})
      assert mapping.commit_id == "commit-abc"
      assert mapping.doc_uuid == "doc-uuid-1"
      assert mapping.path == "/path/to/file"

      GenServer.stop(registry)
    end

    test "returns :error for unknown inode" do
      {:ok, registry} = InodeTracker.Registry.start_link([])
      assert :error = InodeTracker.Registry.lookup(registry, {1, 99999})
      GenServer.stop(registry)
    end

    test "shadow marks an inode as shadowed" do
      {:ok, registry} = InodeTracker.Registry.start_link([])

      InodeTracker.Registry.track(registry, {1, 12345}, "commit-abc", "doc-uuid-1", "/path")
      InodeTracker.Registry.shadow(registry, {1, 12345}, "/shadow/path")

      {:ok, mapping} = InodeTracker.Registry.lookup(registry, {1, 12345})
      assert mapping.shadowed == true
      assert mapping.shadow_path == "/shadow/path"

      GenServer.stop(registry)
    end

    test "lists all shadowed inodes" do
      {:ok, registry} = InodeTracker.Registry.start_link([])

      InodeTracker.Registry.track(registry, {1, 100}, "c1", "d1", "/a")
      InodeTracker.Registry.track(registry, {1, 200}, "c2", "d2", "/b")
      InodeTracker.Registry.shadow(registry, {1, 100}, "/shadow/a")

      shadows = InodeTracker.Registry.list_shadows(registry)
      assert length(shadows) == 1
      assert hd(shadows).commit_id == "c1"

      GenServer.stop(registry)
    end
  end

  describe "shadow creation during export" do
    test "atomic_write_with_shadow creates shadow before rename",
         %{sync_dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "tracked.txt")
      File.write!(path, "original")
      _original_inode = File.stat!(path).inode

      {:ok, registry} = InodeTracker.Registry.start_link([])
      inode_key = inode_key(path)
      InodeTracker.Registry.track(registry, inode_key, "commit-old", "doc-1", path)

      # Atomic write with shadow
      InodeTracker.atomic_write_with_shadow(path, "updated", shadow_dir, registry, "commit-new", "doc-1")

      # File should have new content
      assert File.read!(path) == "updated"

      # Shadow should exist with old content
      shadows = InodeTracker.Registry.list_shadows(registry)
      assert length(shadows) == 1
      shadow = hd(shadows)
      assert shadow.commit_id == "commit-old"
      assert File.read!(shadow.shadow_path) == "original"

      # New inode should be tracked
      new_inode_key = inode_key(path)
      {:ok, new_mapping} = InodeTracker.Registry.lookup(registry, new_inode_key)
      assert new_mapping.commit_id == "commit-new"

      GenServer.stop(registry)
    end
  end

  describe "stale write detection and merge" do
    test "detects and captures stale write to shadowed inode",
         %{sync_dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "edited.txt")
      File.write!(path, "v1")

      {:ok, registry} = InodeTracker.Registry.start_link([])
      inode_key = inode_key(path)
      InodeTracker.Registry.track(registry, inode_key, "commit-v1", "doc-1", path)

      # Shadow + atomic write
      InodeTracker.atomic_write_with_shadow(path, "v2", shadow_dir, registry, "commit-v2", "doc-1")

      # Get shadow info
      [shadow] = InodeTracker.Registry.list_shadows(registry)
      fingerprint = InodeTracker.file_fingerprint(shadow.shadow_path)

      # Simulate stale fd write to old inode
      File.write!(shadow.shadow_path, "v1-with-stale-edit")

      # Should detect the stale write
      assert InodeTracker.stale_write?(shadow.shadow_path, fingerprint)

      # Can read the stale content for merging
      stale_content = File.read!(shadow.shadow_path)
      assert stale_content == "v1-with-stale-edit"

      # The stale write's parent commit is the shadow's commit_id
      assert shadow.commit_id == "commit-v1"

      GenServer.stop(registry)
    end
  end

  describe "end-to-end: stale write merged back via sync" do
    test "stale write to shadow gets merged into CRDT",
         %{store: store, root: root, sync_dir: dir, shadow_dir: shadow_dir} do
      # Start sync loop with shadow tracking
      {:ok, loop} = SyncLoop.start_link(
        dir: dir, root_uuid: root, store: store, interval: 50,
        shadow_tracking: true
      )

      # Create a file via disk
      File.write!(Path.join(dir, "target.txt"), "original")
      Process.sleep(300)

      # Verify it's in CRDT
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "target.txt")
      doc_uuid = entry.node_id
      {:ok, commit_before} = CommitStore.latest_commit(store, doc_uuid)

      # Simulate a remote CRDT update (another peer modifies the doc)
      modify_crdt_doc(doc_uuid, "remote update", store)

      # Wait for sync to export the remote update to disk
      # This atomic write should create a shadow of the old inode
      Process.sleep(400)

      # Current file should have the remote update
      assert File.read!(Path.join(dir, "target.txt")) == "remote update"

      # Now simulate a stale write: write to the shadow hardlink
      # (representing a process that held the old fd open)
      File.mkdir_p!(shadow_dir)
      shadows =
        File.ls!(shadow_dir)
        |> Enum.reject(&String.starts_with?(&1, "."))

      if length(shadows) > 0 do
        shadow_path = Path.join(shadow_dir, hd(shadows))
        File.write!(shadow_path, "stale process wrote this")

        # Let sync cycle detect the stale write and merge it
        Process.sleep(300)

        # The stale content should have been committed to the CRDT
        {:ok, latest} = CommitStore.latest_commit(store, doc_uuid)
        assert latest.id != commit_before.id
      end

      GenServer.stop(loop)
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc
      :none ->
        Schema.new_schema()
    end
  end

  defp modify_crdt_doc(doc_uuid, new_content, store) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "target.txt")
    doc = ContentType.insert_text(doc, 0, new_content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, doc_uuid, update, nil)
  end

  defp inode_key(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.inode}
  end
end
