defmodule Commonplace.Tree.DocBuilderTest do
  @moduledoc """
  Tests for DocBuilder — verifies doc reconstruction from commit chains.
  """
  use ExUnit.Case

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_docbuilder_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"docbuilder_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  describe "reconstruct_doc/2" do
    test "returns :none for unknown UUID", %{store: store} do
      assert :none = DocBuilder.reconstruct_doc(store, "nonexistent-uuid")
    end

    test "reconstructs doc from single commit", %{store: store} do
      doc = Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "hello")
      update = Encoding.encode_update(doc)

      CommitStore.create_commit(store, "doc-1", update, nil)

      assert {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "hello"
    end

    test "reconstructs doc from multiple chained commits", %{store: store} do
      # First commit: create doc with initial text
      doc1 = Doc.new(client_id: 1)
      doc1 = ContentType.create(doc1, :text, "test.txt")
      doc1 = ContentType.insert_text(doc1, 0, "hello")
      update1 = Encoding.encode_update(doc1)
      CommitStore.create_commit(store, "doc-1", update1, nil)

      # Second commit: append " world" using incremental update
      {:ok, doc2} = Encoding.apply_update(Doc.new(), update1)
      doc2 = ContentType.insert_text(doc2, 5, " world")
      sv = Yelixer.BlockStore.state_vector(doc1.store)
      diff = Encoding.encode_diff(doc2, sv)
      CommitStore.create_chained_commit(store, "doc-1", diff)

      assert {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "hello world"
    end
  end

  describe "reconstruct_snapshot/2" do
    test "returns :none for unknown UUID", %{store: store} do
      assert :none = DocBuilder.reconstruct_snapshot(store, "nonexistent-uuid")
    end

    test "reconstructs doc from latest commit only", %{store: store} do
      doc = Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "latest content")
      update = Encoding.encode_update(doc)

      CommitStore.create_commit(store, "doc-1", update, nil)

      assert {:ok, rebuilt} = DocBuilder.reconstruct_snapshot(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "latest content"
    end

    test "uses only the latest commit, not the full chain", %{store: store} do
      # Create two full-snapshot commits (as fork/schema would)
      doc1 = Doc.new()
      doc1 = ContentType.create(doc1, :text, "test.txt")
      doc1 = ContentType.insert_text(doc1, 0, "version 1")
      update1 = Encoding.encode_update(doc1)
      CommitStore.create_commit(store, "doc-1", update1, nil)

      doc2 = Doc.new()
      doc2 = ContentType.create(doc2, :text, "test.txt")
      doc2 = ContentType.insert_text(doc2, 0, "version 2")
      update2 = Encoding.encode_update(doc2)
      CommitStore.create_chained_commit(store, "doc-1", update2)

      assert {:ok, rebuilt} = DocBuilder.reconstruct_snapshot(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "version 2"
    end
  end

  describe "reconstruct_doc/2 with snapshot commits (CX-u7p)" do
    test "stops backward walk at the most recent snapshot commit", %{store: store} do
      # Build a chain whose pre-snapshot commits encode bogus state
      # (random bytes that would fail to decode if applied). The
      # snapshot commit is the only one that should actually be applied.
      CommitStore.create_commit(store, "doc-1", <<255, 254, 253>>, nil)
      CommitStore.create_chained_commit(store, "doc-1", <<252, 251, 250>>)

      # Now lay down a real snapshot
      doc = Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "snap content")
      snap_update = Encoding.encode_update(doc)
      CommitStore.create_snapshot_commit(store, "doc-1", snap_update)

      # Replay should start at the snapshot, ignoring the garbage
      # before it.
      assert {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "snap content"
    end

    test "applies commits chained on top of the snapshot", %{store: store} do
      # Lay down a snapshot
      doc = Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "hello")
      snap_update = Encoding.encode_update(doc)
      CommitStore.create_snapshot_commit(store, "doc-1", snap_update)

      # Append a normal incremental commit on top
      {:ok, doc2} = Encoding.apply_update(Doc.new(), snap_update)
      doc2 = ContentType.insert_text(doc2, 5, " world")
      sv = Yelixer.BlockStore.state_vector(doc.store)
      diff = Encoding.encode_diff(doc2, sv)
      CommitStore.create_chained_commit(store, "doc-1", diff)

      assert {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "hello world"
    end

    test "uses the most recent snapshot when multiple snapshots exist", %{store: store} do
      # First snapshot — should be ignored
      doc1 = Doc.new()
      doc1 = ContentType.create(doc1, :text, "test.txt")
      doc1 = ContentType.insert_text(doc1, 0, "first")
      CommitStore.create_snapshot_commit(store, "doc-1", Encoding.encode_update(doc1))

      # Second snapshot — should be the start
      doc2 = Doc.new()
      doc2 = ContentType.create(doc2, :text, "test.txt")
      doc2 = ContentType.insert_text(doc2, 0, "second")
      CommitStore.create_snapshot_commit(store, "doc-1", Encoding.encode_update(doc2))

      assert {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "second"
    end

    test "non-snapshot chains still replay fully (backward compatible)", %{store: store} do
      # No snapshots anywhere — behavior should match the pre-CX-u7p path.
      doc1 = Doc.new(client_id: 1)
      doc1 = ContentType.create(doc1, :text, "test.txt")
      doc1 = ContentType.insert_text(doc1, 0, "hello")
      update1 = Encoding.encode_update(doc1)
      CommitStore.create_commit(store, "doc-1", update1, nil)

      {:ok, doc2} = Encoding.apply_update(Doc.new(), update1)
      doc2 = ContentType.insert_text(doc2, 5, " world")
      sv = Yelixer.BlockStore.state_vector(doc1.store)
      diff = Encoding.encode_diff(doc2, sv)
      CommitStore.create_chained_commit(store, "doc-1", diff)

      assert {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, "doc-1")
      assert ContentType.get_content(rebuilt) == "hello world"
    end

    test "chain walk from :latest still reaches root through a mid-chain snapshot",
         %{store: store} do
      # Replication-style sanity check: the parent_id chain from :latest
      # back to the original root commit must remain intact when a
      # snapshot is inserted in the middle. Peers walk via parent_id;
      # the snapshot is just an ordinary commit on the wire.
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>)
      c2 = CommitStore.create_chained_commit(store, "doc-1", <<2>>)

      {:ok, fetched_c2} = CommitStore.get_commit(store, c2.id)
      assert fetched_c2.parent_id == snap.id

      {:ok, fetched_snap} = CommitStore.get_commit(store, snap.id)
      assert fetched_snap.parent_id == c1.id
      assert fetched_snap.metadata.kind == :snapshot

      {:ok, fetched_c1} = CommitStore.get_commit(store, c1.id)
      assert fetched_c1.parent_id == nil
    end
  end

  describe "reconstruct_doc_at/3" do
    test "returns :none when target commit not in chain", %{store: store} do
      doc = Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "hello")
      update = Encoding.encode_update(doc)
      CommitStore.create_commit(store, "doc-1", update, nil)

      assert :none = DocBuilder.reconstruct_doc_at(store, "doc-1", <<0::256>>)
    end

    test "returns :none for unknown UUID", %{store: store} do
      assert :none = DocBuilder.reconstruct_doc_at(store, "nonexistent", <<0::256>>)
    end

    test "reconstructs doc up to a specific commit", %{store: store} do
      # Create three commits
      doc1 = Doc.new(client_id: 1)
      doc1 = ContentType.create(doc1, :text, "test.txt")
      doc1 = ContentType.insert_text(doc1, 0, "a")
      update1 = Encoding.encode_update(doc1)
      c1 = CommitStore.create_commit(store, "doc-1", update1, nil)

      {:ok, doc2} = Encoding.apply_update(Doc.new(), update1)
      doc2 = ContentType.insert_text(doc2, 1, "b")
      sv1 = Yelixer.BlockStore.state_vector(doc1.store)
      diff2 = Encoding.encode_diff(doc2, sv1)
      c2 = CommitStore.create_chained_commit(store, "doc-1", diff2)

      {:ok, doc3} = Encoding.apply_update(Doc.new(), Encoding.encode_update(doc2))
      doc3 = ContentType.insert_text(doc3, 2, "c")
      sv2 = Yelixer.BlockStore.state_vector(doc2.store)
      diff3 = Encoding.encode_diff(doc3, sv2)
      _c3 = CommitStore.create_chained_commit(store, "doc-1", diff3)

      # Reconstruct at c1 — should only have "a"
      assert {:ok, at_c1} = DocBuilder.reconstruct_doc_at(store, "doc-1", c1.id)
      assert ContentType.get_content(at_c1) == "a"

      # Reconstruct at c2 — should have "ab"
      assert {:ok, at_c2} = DocBuilder.reconstruct_doc_at(store, "doc-1", c2.id)
      assert ContentType.get_content(at_c2) == "ab"
    end
  end
end
