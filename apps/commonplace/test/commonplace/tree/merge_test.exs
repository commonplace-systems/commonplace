defmodule Commonplace.Tree.MergeTest do
  use ExUnit.Case

  alias Commonplace.Tree.{Merge, Schema, Fork, ForkManifest}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_merge_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_merge_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  describe "reconstruct_doc/2" do
    test "reconstructs doc from single commit", %{store: store} do
      uuid = create_text_doc(store, "test.txt", "hello")
      {:ok, doc} = Merge.reconstruct_doc(store, uuid)
      assert ContentType.get_content(doc) == "hello"
    end

    test "reconstructs doc from commit chain", %{store: store} do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "hello")
      update1 = Yelixer.Encoding.encode_update(doc)
      commit1 = CommitStore.create_commit(store, uuid, update1, nil)

      doc = ContentType.insert_text(doc, 5, " world")
      update2 = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update2, commit1.id)

      {:ok, reconstructed} = Merge.reconstruct_doc(store, uuid)
      assert ContentType.get_content(reconstructed) == "hello world"
    end

    test "returns :none for unknown uuid", %{store: store} do
      assert :none = Merge.reconstruct_doc(store, "nonexistent")
    end
  end

  describe "reconstruct_doc_at/3" do
    test "reconstructs doc up to a specific commit", %{store: store} do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "v1")
      update1 = Yelixer.Encoding.encode_update(doc)
      commit1 = CommitStore.create_commit(store, uuid, update1, nil)

      doc = ContentType.insert_text(doc, 2, " v2")
      update2 = Yelixer.Encoding.encode_update(doc)
      _commit2 = CommitStore.create_commit(store, uuid, update2, commit1.id)

      {:ok, at_v1} = Merge.reconstruct_doc_at(store, uuid, commit1.id)
      assert ContentType.get_content(at_v1) == "v1"
    end
  end

  describe "merge_content_doc/4" do
    test "merges source changes into target", %{store: store} do
      # Create target doc
      target_uuid = create_text_doc(store, "test.txt", "hello")
      {:ok, target_commit} = CommitStore.latest_commit(store, target_uuid)

      # Create source as a copy (simulating fork)
      source_uuid = UUID.uuid4()
      {:ok, target_doc} = Merge.reconstruct_doc(store, target_uuid)
      fork_update = Yelixer.Encoding.encode_update(target_doc)
      CommitStore.create_commit(store, source_uuid, fork_update, nil)

      # Edit source: append " world"
      {:ok, source_doc} = Merge.reconstruct_doc(store, source_uuid)
      source_doc = ContentType.insert_text(source_doc, 5, " world")
      source_update = Yelixer.Encoding.encode_update(source_doc)
      {:ok, source_prev} = CommitStore.latest_commit(store, source_uuid)
      CommitStore.create_commit(store, source_uuid, source_update, source_prev.id)

      # Merge: fork_point_commit is the TARGET commit at fork time
      {:ok, _commit} =
        Merge.merge_content_doc(store, source_uuid, target_uuid, target_commit.id)

      {:ok, result_doc} = Merge.reconstruct_doc(store, target_uuid)
      assert ContentType.get_content(result_doc) =~ "hello"
      assert ContentType.get_content(result_doc) =~ "world"
    end

    test "no-op when source unchanged since fork", %{store: store} do
      target_uuid = create_text_doc(store, "test.txt", "unchanged")
      {:ok, target_commit} = CommitStore.latest_commit(store, target_uuid)

      source_uuid = UUID.uuid4()
      {:ok, target_doc} = Merge.reconstruct_doc(store, target_uuid)
      CommitStore.create_commit(store, source_uuid, Yelixer.Encoding.encode_update(target_doc), nil)

      # No edits on source
      assert :noop = Merge.merge_content_doc(store, source_uuid, target_uuid, target_commit.id)
    end
  end

  describe "diff_schemas/2" do
    test "detects added entries" do
      fork_point = %{"file1.txt" => %{"type" => "doc", "node_id" => "aaa"}}
      current = %{
        "file1.txt" => %{"type" => "doc", "node_id" => "aaa"},
        "file2.txt" => %{"type" => "doc", "node_id" => "bbb"}
      }

      diff = Merge.diff_schemas(fork_point, current)
      assert diff.added == %{"file2.txt" => %{"type" => "doc", "node_id" => "bbb"}}
      assert diff.removed == %{}
      assert diff.renamed == []
    end

    test "detects removed entries" do
      fork_point = %{
        "file1.txt" => %{"type" => "doc", "node_id" => "aaa"},
        "file2.txt" => %{"type" => "doc", "node_id" => "bbb"}
      }
      current = %{"file1.txt" => %{"type" => "doc", "node_id" => "aaa"}}

      diff = Merge.diff_schemas(fork_point, current)
      assert diff.removed == %{"file2.txt" => %{"type" => "doc", "node_id" => "bbb"}}
      assert diff.added == %{}
    end

    test "detects renames via node_id match" do
      fork_point = %{"old.txt" => %{"type" => "doc", "node_id" => "aaa"}}
      current = %{"new.txt" => %{"type" => "doc", "node_id" => "aaa"}}

      diff = Merge.diff_schemas(fork_point, current)
      assert diff.renamed == [{"old.txt", "new.txt", "aaa"}]
      assert diff.added == %{}
      assert diff.removed == %{}
    end

    test "handles mixed adds, removes, and renames" do
      fork_point = %{
        "keep.txt" => %{"type" => "doc", "node_id" => "aaa"},
        "rename_me.txt" => %{"type" => "doc", "node_id" => "bbb"},
        "delete_me.txt" => %{"type" => "doc", "node_id" => "ccc"}
      }
      current = %{
        "keep.txt" => %{"type" => "doc", "node_id" => "aaa"},
        "renamed.txt" => %{"type" => "doc", "node_id" => "bbb"},
        "new.txt" => %{"type" => "doc", "node_id" => "ddd"}
      }

      diff = Merge.diff_schemas(fork_point, current)
      assert diff.added == %{"new.txt" => %{"type" => "doc", "node_id" => "ddd"}}
      assert diff.removed == %{"delete_me.txt" => %{"type" => "doc", "node_id" => "ccc"}}
      assert diff.renamed == [{"rename_me.txt", "renamed.txt", "bbb"}]
    end
  end

  describe "apply_schema_changes/7" do
    test "copies added file entries to target with new UUIDs", %{store: store} do
      target_root = UUID.uuid4()
      target_doc = Schema.new_schema()
      target_doc = Schema.add_file(target_doc, "existing.txt", UUID.uuid4())
      CommitStore.create_commit(store, target_root, Yelixer.Encoding.encode_update(target_doc), nil)

      new_source_uuid = create_text_doc(store, "added.txt", "new content")

      diff = %Merge.SchemaDiff{
        added: %{"added.txt" => %{"type" => "doc", "node_id" => new_source_uuid}},
        removed: %{},
        renamed: []
      }

      manifest = ForkManifest.new(target_root)
      target_entries = Schema.entries(target_doc)

      {updated_doc, updated_manifest, report} =
        Merge.apply_schema_changes(store, target_doc, diff, manifest, target_entries, %Merge.MergeReport{})

      {:ok, entry} = Schema.get_entry(updated_doc, "added.txt")
      assert entry.node_id != new_source_uuid
      assert length(report.new_docs) == 1
      assert map_size(updated_manifest.document_map) > map_size(manifest.document_map)
    end

    test "copies added directory entries via Fork.fork_directory", %{store: store} do
      inner_uuid = create_text_doc(store, "inner.txt", "nested content")
      subdir_uuid = UUID.uuid4()
      subdir_doc = Schema.new_schema()
      subdir_doc = Schema.add_file(subdir_doc, "inner.txt", inner_uuid)
      CommitStore.create_commit(store, subdir_uuid, Yelixer.Encoding.encode_update(subdir_doc), nil)

      target_doc = Schema.new_schema()
      manifest = ForkManifest.new(UUID.uuid4())

      diff = %Merge.SchemaDiff{
        added: %{"subdir" => %{"type" => "dir", "node_id" => subdir_uuid}},
        removed: %{},
        renamed: []
      }

      target_entries = Schema.entries(target_doc)

      {updated_doc, _manifest, report} =
        Merge.apply_schema_changes(store, target_doc, diff, manifest, target_entries, %Merge.MergeReport{})

      {:ok, entry} = Schema.get_entry(updated_doc, "subdir")
      assert entry.type == :dir
      assert entry.node_id != subdir_uuid
      assert length(report.new_docs) == 1
    end

    test "detects delete-vs-modify conflict", %{store: store} do
      target_file_uuid = create_text_doc(store, "contested.txt", "original")
      {:ok, fork_commit} = CommitStore.latest_commit(store, target_file_uuid)

      {:ok, target_file_doc} = Merge.reconstruct_doc(store, target_file_uuid)
      target_file_doc = ContentType.insert_text(target_file_doc, 8, " edited")
      update = Yelixer.Encoding.encode_update(target_file_doc)
      CommitStore.create_commit(store, target_file_uuid, update, fork_commit.id)

      source_uuid = UUID.uuid4()
      diff = %Merge.SchemaDiff{
        added: %{},
        removed: %{"contested.txt" => %{"type" => "doc", "node_id" => source_uuid}},
        renamed: []
      }

      target_doc = Schema.new_schema()
      target_doc = Schema.add_file(target_doc, "contested.txt", target_file_uuid)

      manifest = ForkManifest.new("root")
      manifest = ForkManifest.add_entry(manifest, source_uuid, target_file_uuid, fork_commit.id)
      target_entries = Schema.entries(target_doc)

      {updated_doc, _manifest, report} =
        Merge.apply_schema_changes(store, target_doc, diff, manifest, target_entries, %Merge.MergeReport{})

      assert {:ok, _} = Schema.get_entry(updated_doc, "contested.txt")
      assert [{:delete_vs_modify, "contested.txt", ^target_file_uuid}] = report.conflicts
    end

    test "safely removes unmodified deleted entries", %{store: store} do
      target_file_uuid = create_text_doc(store, "deletable.txt", "original")
      {:ok, fork_commit} = CommitStore.latest_commit(store, target_file_uuid)

      source_uuid = UUID.uuid4()
      diff = %Merge.SchemaDiff{
        added: %{},
        removed: %{"deletable.txt" => %{"type" => "doc", "node_id" => source_uuid}},
        renamed: []
      }

      target_doc = Schema.new_schema()
      target_doc = Schema.add_file(target_doc, "deletable.txt", target_file_uuid)

      manifest = ForkManifest.new("root")
      manifest = ForkManifest.add_entry(manifest, source_uuid, target_file_uuid, fork_commit.id)
      target_entries = Schema.entries(target_doc)

      {updated_doc, _manifest, report} =
        Merge.apply_schema_changes(store, target_doc, diff, manifest, target_entries, %Merge.MergeReport{})

      assert :error = Schema.get_entry(updated_doc, "deletable.txt")
      assert [^target_file_uuid] = report.deleted_docs
      assert report.conflicts == []
    end

    test "detects name collision", %{store: store} do
      source_uuid = create_text_doc(store, "same.txt", "source version")
      target_uuid = create_text_doc(store, "same.txt", "target version")

      diff = %Merge.SchemaDiff{
        added: %{"same.txt" => %{"type" => "doc", "node_id" => source_uuid}},
        removed: %{},
        renamed: []
      }

      target_doc = Schema.new_schema()
      target_doc = Schema.add_file(target_doc, "same.txt", target_uuid)

      manifest = ForkManifest.new("root")
      target_entries = Schema.entries(target_doc)

      {_doc, _manifest, report} =
        Merge.apply_schema_changes(store, target_doc, diff, manifest, target_entries, %Merge.MergeReport{},
          fork_point_target_entries: %{}
        )

      assert [{:name_collision, "same.txt", ^source_uuid, ^target_uuid}] = report.conflicts
    end

    test "applies renames preserving entry type", %{store: store} do
      target_file_uuid = create_text_doc(store, "old.txt", "content")

      target_doc = Schema.new_schema()
      target_doc = Schema.add_file(target_doc, "old.txt", target_file_uuid)

      source_node_id = UUID.uuid4()
      diff = %Merge.SchemaDiff{
        added: %{},
        removed: %{},
        renamed: [{"old.txt", "new.txt", source_node_id}]
      }

      manifest = ForkManifest.new("root")
      manifest = ForkManifest.add_entry(manifest, source_node_id, target_file_uuid, <<0::256>>)
      target_entries = Schema.entries(target_doc)

      {updated_doc, _manifest, _report} =
        Merge.apply_schema_changes(store, target_doc, diff, manifest, target_entries, %Merge.MergeReport{})

      assert :error = Schema.get_entry(updated_doc, "old.txt")
      assert {:ok, entry} = Schema.get_entry(updated_doc, "new.txt")
      assert entry.node_id == target_file_uuid
      assert entry.type == :doc
    end
  end

  defp create_text_doc(store, name, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end
end
