defmodule Commonplace.Tree.ForkTest do
  use ExUnit.Case

  alias Commonplace.Tree.{Fork, Schema}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_fork_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_fork_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  test "forks a simple directory with files", %{store: store} do
    file1_uuid = create_text_doc(store, "file1.txt", "content one")
    file2_uuid = create_text_doc(store, "file2.txt", "content two")

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "file1.txt", file1_uuid)
    root_doc = Schema.add_file(root_doc, "file2.txt", file2_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    new_root = Fork.fork_directory(root_uuid, store)

    # New root has different UUID
    assert new_root != root_uuid

    # New root has a schema with different child UUIDs
    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, e1} = Schema.get_entry(schema, "file1.txt")
    {:ok, e2} = Schema.get_entry(schema, "file2.txt")
    assert e1.node_id != file1_uuid
    assert e2.node_id != file2_uuid

    # Forked leaf docs share commit history — common ancestor exists
    {:ok, ancestor} = CommitStore.find_common_ancestor(store, file1_uuid, e1.node_id)
    assert ancestor != nil

    # Content is preserved
    {:ok, fork_commit} = CommitStore.latest_commit(store, e1.node_id)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, fork_commit.update)
    assert ContentType.get_content(doc) == "content one"
  end

  test "forked documents share commit chains", %{store: store} do
    file_uuid = create_text_doc(store, "test.txt", "original")
    {:ok, orig_commit} = CommitStore.latest_commit(store, file_uuid)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "test.txt", file_uuid)
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

    new_root = Fork.fork_directory(root_uuid, store)

    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, entry} = Schema.get_entry(schema, "test.txt")

    # The forked leaf's chain includes the original commit
    log = CommitStore.commit_log(store, entry.node_id)
    commit_ids = Enum.map(log, & &1.id)
    assert orig_commit.id in commit_ids
  end

  test "forks nested directories", %{store: store} do
    inner_file = create_text_doc(store, "inner.txt", "nested")

    inner_uuid = UUID.uuid4()
    inner_doc = Schema.new_schema()
    inner_doc = Schema.add_file(inner_doc, "inner.txt", inner_file)
    CommitStore.create_commit(store, inner_uuid, Yelixer.Encoding.encode_update(inner_doc), nil)

    outer_uuid = UUID.uuid4()
    outer_doc = Schema.new_schema()
    outer_doc = Schema.add_directory(outer_doc, "subdir", inner_uuid)
    CommitStore.create_commit(store, outer_uuid, Yelixer.Encoding.encode_update(outer_doc), nil)

    new_root = Fork.fork_directory(outer_uuid, store)
    assert new_root != outer_uuid

    # Verify nested structure exists
    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, subdir_entry} = Schema.get_entry(schema, "subdir")
    assert subdir_entry.type == :dir
    assert subdir_entry.node_id != inner_uuid
  end

  test "fork_behavior defaults" do
    assert Config.fork_behavior(%Config{mode: :sandbox_exec}) == :skip
    assert Config.fork_behavior(%Config{mode: :elixir}) == :copy
    assert Config.fork_behavior(%Config{mode: :command}) == :skip
    assert Config.fork_behavior(%Config{mode: :command, fork: :copy}) == :copy
  end

  test "filters __processes.json during fork", %{store: store} do
    proc_content =
      Jason.encode!(%{
        "safe_elixir" => %{"mode" => "elixir", "source" => "worker.exs"},
        "singleton" => %{"mode" => "command", "command" => "run"}
      })

    proc_uuid = create_text_doc(store, "__processes.json", proc_content)
    file_uuid = create_text_doc(store, "data.txt", "data")

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "__processes.json", proc_uuid)
    root_doc = Schema.add_file(root_doc, "data.txt", file_uuid)
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

    new_root = Fork.fork_directory(root_uuid, store)

    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, proc_entry} = Schema.get_entry(schema, "__processes.json")

    {:ok, proc_commit} = CommitStore.latest_commit(store, proc_entry.node_id)
    proc_doc = Yelixer.Doc.new()
    {:ok, proc_doc} = Yelixer.Encoding.apply_update(proc_doc, proc_commit.update)
    content = ContentType.get_content(proc_doc)
    parsed = Jason.decode!(content)

    assert Map.has_key?(parsed, "safe_elixir")
    refute Map.has_key?(parsed, "singleton")
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
