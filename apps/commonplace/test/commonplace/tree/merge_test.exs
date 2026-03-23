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
