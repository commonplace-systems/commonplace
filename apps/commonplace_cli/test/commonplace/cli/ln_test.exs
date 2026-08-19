defmodule Commonplace.CLI.LnTest do
  @moduledoc """
  Tests for commonplace ln — CRDT-native hardlinks.
  """
  use ExUnit.Case

  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ln_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  describe "linking documents" do
    test "ln creates a second entry pointing to the same UUID", %{store: store, root: root} do
      # Create source doc
      uuid = create_doc(store, root, "source.txt", "shared content")

      # Link it
      :ok = Commonplace.CLI.Ln.link("source.txt", "alias.txt", root, store)

      # Both entries should point to the same UUID
      root_doc = load_schema(root, store)
      {:ok, source_entry} = Schema.get_entry(root_doc, "source.txt")
      {:ok, alias_entry} = Schema.get_entry(root_doc, "alias.txt")

      assert source_entry.node_id == alias_entry.node_id
      assert source_entry.node_id == uuid
    end

    test "linked doc content is the same", %{store: store, root: root} do
      create_doc(store, root, "original.txt", "hello world")
      :ok = Commonplace.CLI.Ln.link("original.txt", "linked.txt", root, store)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "linked.txt")
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert ContentType.get_content(doc) == "hello world"
    end

    test "returns error when source doesn't exist", %{store: store, root: root} do
      assert {:error, :source_not_found} =
               Commonplace.CLI.Ln.link("ghost.txt", "alias.txt", root, store)
    end

    test "refuses to link to a reserved honorific extension (CX-edy)",
         %{store: store, root: root} do
      create_doc(store, root, "ok.txt", "payload")

      for target <- ["shadow.bot", "shadow.exe", "shadow.usr", "shadow.who"] do
        assert {:error, :forbidden_extension} =
                 Commonplace.CLI.Ln.link("ok.txt", target, root, store)
      end
    end

    test "writing to linked doc is visible from both paths", %{store: store, root: root} do
      uuid = create_doc(store, root, "shared.txt", "v1")
      :ok = Commonplace.CLI.Ln.link("shared.txt", "mirror.txt", root, store)

      # Update the doc via its UUID (simulating an edit from either path)
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "shared.txt")
      doc = ContentType.insert_text(doc, 0, "v2")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)

      # Both paths see the update
      root_doc = load_schema(root, store)

      {:ok, e1} = Schema.get_entry(root_doc, "shared.txt")
      {:ok, e2} = Schema.get_entry(root_doc, "mirror.txt")
      assert e1.node_id == e2.node_id

      {:ok, commit} = CommitStore.latest_commit(store, e1.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert ContentType.get_content(doc) == "v2"
    end
  end

  defp create_doc(store, root, filename, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)

    root_doc = load_schema(root, store)
    root_doc = Schema.add_file(root_doc, filename, uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root, update, nil)

    uuid
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
end
