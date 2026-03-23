defmodule Commonplace.Store.GCTest do
  use ExUnit.Case

  alias Commonplace.Store.{GC, CommitStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_gc_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_gc_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  test "finds no orphans when all docs are reachable", %{store: store} do
    root_uuid = UUID.uuid4()
    file_uuid = UUID.uuid4()

    # Create a file doc
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "file.txt")
    doc = ContentType.insert_text(doc, 0, "content")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)

    # Create root schema referencing the file
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "file.txt", file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    {reachable, orphaned} = GC.find_orphans(root_uuid, store)
    assert MapSet.member?(reachable, root_uuid)
    assert MapSet.member?(reachable, file_uuid)
    assert MapSet.size(orphaned) == 0
  end

  test "finds orphaned documents", %{store: store} do
    root_uuid = UUID.uuid4()
    file_uuid = UUID.uuid4()
    orphan_uuid = UUID.uuid4()

    # Create a file doc
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "file.txt")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)

    # Create an orphan (not referenced by any schema)
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "orphan.txt")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, orphan_uuid, update, nil)

    # Create root schema referencing only the file
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "file.txt", file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    {reachable, orphaned} = GC.find_orphans(root_uuid, store)
    assert MapSet.member?(reachable, root_uuid)
    assert MapSet.member?(reachable, file_uuid)
    refute MapSet.member?(reachable, orphan_uuid)
    assert MapSet.member?(orphaned, orphan_uuid)
    assert MapSet.size(orphaned) == 1
  end

  test "report returns stats", %{store: store} do
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    report = GC.report(root_uuid, store)
    assert report.reachable_count == 1
    assert report.orphaned_count == 0
    assert MapSet.size(report.orphaned_uuids) == 0
  end

  test "all_doc_uuids returns all stored UUIDs", %{store: store} do
    uuid1 = UUID.uuid4()
    uuid2 = UUID.uuid4()

    doc = Yelixer.Doc.new()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid1, update, nil)
    CommitStore.create_commit(store, uuid2, update, nil)

    all = CommitStore.all_doc_uuids(store)
    assert MapSet.member?(all, uuid1)
    assert MapSet.member?(all, uuid2)
  end
end
