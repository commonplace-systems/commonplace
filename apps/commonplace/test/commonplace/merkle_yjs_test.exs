defmodule Commonplace.MerkleYjsTest do
  @moduledoc """
  Integration tests for Merkle-wrapped Yjs: the composition of
  the CRDT layer (Yelixer) with the commit DAG layer (CommitStore).
  """
  use ExUnit.Case

  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  describe "commit and reconstruct" do
    test "document state survives commit/replay roundtrip", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "text", :text)
      doc = Yelixer.Types.Text.insert(doc, "text", 0, "hello world")

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "doc-1", update, nil)

      {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      new_doc = Yelixer.Doc.new(client_id: 2)
      {new_doc, _} = Yelixer.Doc.get_or_create_type(new_doc, "text", :text)
      {:ok, new_doc} = Yelixer.Encoding.apply_update(new_doc, fetched.update)

      assert Yelixer.Types.Text.to_string(new_doc, "text") == "hello world"
    end

    test "multiple commits form a replayable history", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "text", :text)
      doc = Yelixer.Types.Text.insert(doc, "text", 0, "hello")

      update1 = Yelixer.Encoding.encode_update(doc)
      c1 = CommitStore.create_commit(store, "doc-1", update1, nil)

      doc = Yelixer.Types.Text.insert(doc, "text", 5, " world")
      update2 = Yelixer.Encoding.encode_update(doc)
      c2 = CommitStore.create_commit(store, "doc-1", update2, c1.id)

      {:ok, latest} = CommitStore.latest_commit(store, "doc-1")
      assert latest.id == c2.id

      reconstructed = Yelixer.Doc.new(client_id: 3)
      {reconstructed, _} = Yelixer.Doc.get_or_create_type(reconstructed, "text", :text)
      {:ok, reconstructed} = Yelixer.Encoding.apply_update(reconstructed, latest.update)

      assert Yelixer.Types.Text.to_string(reconstructed, "text") == "hello world"
    end

    test "YMap data survives commit/replay", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "config", :map)
      doc = Yelixer.Types.YMap.set(doc, "config", "name", "my-workspace")
      doc = Yelixer.Types.YMap.set(doc, "config", "version", "1.0")

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "config-doc", update, nil)

      {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      new_doc = Yelixer.Doc.new(client_id: 2)
      {new_doc, _} = Yelixer.Doc.get_or_create_type(new_doc, "config", :map)
      {:ok, new_doc} = Yelixer.Encoding.apply_update(new_doc, fetched.update)

      assert Yelixer.Types.YMap.get(new_doc, "config", "name") == "my-workspace"
      assert Yelixer.Types.YMap.get(new_doc, "config", "version") == "1.0"
    end

    test "YArray event log survives commit/replay", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "log", :array)
      doc = Yelixer.Types.Array.push(doc, "log", ["event-1"])
      doc = Yelixer.Types.Array.push(doc, "log", ["event-2"])
      doc = Yelixer.Types.Array.push(doc, "log", ["event-3"])

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "log-doc", update, nil)

      {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      new_doc = Yelixer.Doc.new(client_id: 2)
      {new_doc, _} = Yelixer.Doc.get_or_create_type(new_doc, "log", :array)
      {:ok, new_doc} = Yelixer.Encoding.apply_update(new_doc, fetched.update)

      assert Yelixer.Types.Array.to_list(new_doc, "log") == ["event-1", "event-2", "event-3"]
    end
  end

  describe "content addressing" do
    test "same update + same parent produces same commit ID", %{store: store} do
      # Post-CX-m3x: fresh-doc first commits bind the namespace (via their
      # deterministic genesis parent) into the hash, so identical update
      # bytes under DIFFERENT doc_uuids produce DIFFERENT ids — exactly
      # what namespace separation requires. Content addressing still holds
      # within a namespace: identical bytes + identical parent = identical id.
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "text", :text)
      doc = Yelixer.Types.Text.insert(doc, "text", 0, "deterministic")

      update = Yelixer.Encoding.encode_update(doc)
      parent = CommitStore.create_commit(store, "doc-a", <<0>>, nil)
      c1 = CommitStore.create_commit(store, "doc-a", update, parent.id)
      c2 = CommitStore.create_commit(store, "doc-a", update, parent.id)

      assert c1.id == c2.id
    end

    test "commit ID changes when parent changes", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "text", :text)
      doc = Yelixer.Types.Text.insert(doc, "text", 0, "data")

      update = Yelixer.Encoding.encode_update(doc)
      c1 = CommitStore.create_commit(store, "doc-1", update, nil)
      c2 = CommitStore.create_commit(store, "doc-1", update, c1.id)

      assert c1.id != c2.id
    end

    test "tamper detection: modifying update bytes invalidates the chain", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "text", :text)
      doc = Yelixer.Types.Text.insert(doc, "text", 0, "original")

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "doc-1", update, nil)

      # Post-CX-m3x: a fresh-doc first commit now parents to the deterministic
      # genesis, so the hash is sha256(genesis.id <> update). Tampering still
      # breaks the address — the property that matters here.
      expected_id = :crypto.hash(:sha256, commit.parent_id <> commit.update)
      assert commit.id == expected_id

      tampered_update = <<0>> <> commit.update
      tampered_id = :crypto.hash(:sha256, commit.parent_id <> tampered_update)
      assert tampered_id != commit.id
    end
  end

  describe "peer sync via commits" do
    test "two peers converge through committed updates", %{store: store} do
      doc_a = Yelixer.Doc.new(client_id: 1)
      {doc_a, _} = Yelixer.Doc.get_or_create_type(doc_a, "text", :text)
      doc_a = Yelixer.Types.Text.insert(doc_a, "text", 0, "hello from A")

      update_a = Yelixer.Encoding.encode_update(doc_a)
      c1 = CommitStore.create_commit(store, "shared-doc", update_a, nil)

      {:ok, fetched} = CommitStore.get_commit(store, c1.id)
      doc_b = Yelixer.Doc.new(client_id: 2)
      {doc_b, _} = Yelixer.Doc.get_or_create_type(doc_b, "text", :text)
      {:ok, doc_b} = Yelixer.Encoding.apply_update(doc_b, fetched.update)

      doc_b = Yelixer.Types.Text.insert(doc_b, "text", 12, " and B")

      update_b = Yelixer.Encoding.encode_update(doc_b)
      _c2 = CommitStore.create_commit(store, "shared-doc", update_b, c1.id)

      {:ok, doc_a} = Yelixer.Encoding.apply_update(doc_a, update_b)

      assert Yelixer.Types.Text.to_string(doc_a, "text") == "hello from A and B"
      assert Yelixer.Types.Text.to_string(doc_b, "text") == "hello from A and B"
    end

    test "concurrent edits merge correctly after commit exchange", %{store: store} do
      base = Yelixer.Doc.new(client_id: 0)
      {base, _} = Yelixer.Doc.get_or_create_type(base, "text", :text)
      base = Yelixer.Types.Text.insert(base, "text", 0, "base")
      base_update = Yelixer.Encoding.encode_update(base)
      base_commit = CommitStore.create_commit(store, "doc-1", base_update, nil)

      doc_a = Yelixer.Doc.new(client_id: 1)
      {doc_a, _} = Yelixer.Doc.get_or_create_type(doc_a, "text", :text)
      {:ok, doc_a} = Yelixer.Encoding.apply_update(doc_a, base_update)
      doc_a = Yelixer.Types.Text.insert(doc_a, "text", 4, "-A")

      doc_b = Yelixer.Doc.new(client_id: 2)
      {doc_b, _} = Yelixer.Doc.get_or_create_type(doc_b, "text", :text)
      {:ok, doc_b} = Yelixer.Encoding.apply_update(doc_b, base_update)
      doc_b = Yelixer.Types.Text.insert(doc_b, "text", 0, "B-")

      update_a = Yelixer.Encoding.encode_update(doc_a)
      update_b = Yelixer.Encoding.encode_update(doc_b)
      _ca = CommitStore.create_commit(store, "doc-1", update_a, base_commit.id)
      _cb = CommitStore.create_commit(store, "doc-1", update_b, base_commit.id)

      {:ok, doc_a} = Yelixer.Encoding.apply_update(doc_a, update_b)
      {:ok, doc_b} = Yelixer.Encoding.apply_update(doc_b, update_a)

      result_a = Yelixer.Types.Text.to_string(doc_a, "text")
      result_b = Yelixer.Types.Text.to_string(doc_b, "text")

      assert result_a == result_b
      assert String.contains?(result_a, "A")
      assert String.contains?(result_a, "B")
      assert String.contains?(result_a, "base")
    end
  end
end
