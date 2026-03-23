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
