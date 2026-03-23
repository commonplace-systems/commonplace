defmodule Commonplace.Tree.ForkTest do
  use ExUnit.Case

  alias Commonplace.Tree.Fork
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
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

    {new_root, manifest} = Fork.fork_directory(root_uuid, store)

    assert new_root != root_uuid
    assert manifest.forked_from == root_uuid
    assert map_size(manifest.document_map) >= 3

    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    entries = Schema.list_entries(doc)
    names = Enum.map(entries, & &1.name) |> Enum.sort()
    assert names == ["file1.txt", "file2.txt"]

    {:ok, e1} = Schema.get_entry(doc, "file1.txt")
    {:ok, e2} = Schema.get_entry(doc, "file2.txt")
    assert e1.node_id != file1_uuid
    assert e2.node_id != file2_uuid

    {:ok, c1} = CommitStore.latest_commit(store, e1.node_id)
    d1 = Yelixer.Doc.new()
    {:ok, d1} = Yelixer.Encoding.apply_update(d1, c1.update)
    assert ContentType.get_content(d1) == "content one"
  end

  test "forks nested directories", %{store: store} do
    inner_file = create_text_doc(store, "inner.txt", "nested")

    inner_uuid = UUID.uuid4()
    inner_doc = Schema.new_schema()
    inner_doc = Schema.add_file(inner_doc, "inner.txt", inner_file)
    update = Yelixer.Encoding.encode_update(inner_doc)
    CommitStore.create_commit(store, inner_uuid, update, nil)

    outer_uuid = UUID.uuid4()
    outer_doc = Schema.new_schema()
    outer_doc = Schema.add_directory(outer_doc, "subdir", inner_uuid)
    update = Yelixer.Encoding.encode_update(outer_doc)
    CommitStore.create_commit(store, outer_uuid, update, nil)

    {new_root, manifest} = Fork.fork_directory(outer_uuid, store)
    assert new_root != outer_uuid
    assert map_size(manifest.document_map) >= 3
  end

  test "forked documents are independent", %{store: store} do
    file_uuid = create_text_doc(store, "test.txt", "original")

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "test.txt", file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    {new_root, _manifest} = Fork.fork_directory(root_uuid, store)

    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    {:ok, entry} = Schema.get_entry(doc, "test.txt")
    forked_file = entry.node_id

    new_doc = Yelixer.Doc.new()
    new_doc = ContentType.create(new_doc, :text, "test.txt")
    new_doc = ContentType.insert_text(new_doc, 0, "modified")
    update = Yelixer.Encoding.encode_update(new_doc)
    CommitStore.create_commit(store, forked_file, update, nil)

    {:ok, orig_commit} = CommitStore.latest_commit(store, file_uuid)
    orig_doc = Yelixer.Doc.new()
    {:ok, orig_doc} = Yelixer.Encoding.apply_update(orig_doc, orig_commit.update)
    assert ContentType.get_content(orig_doc) == "original"
  end

  test "filter_for_fork removes skip-marked processes" do
    json = %{
      "elixir_safe" => %{"mode" => "elixir", "source" => "worker.exs"},
      "sandbox_default" => %{"mode" => "sandbox-exec", "command" => "echo"},
      "dangerous" => %{"mode" => "command", "command" => "rm", "args" => ["-rf"]},
      "explicit_skip" => %{"mode" => "elixir", "source" => "x.exs", "fork" => "skip"},
      "explicit_copy" => %{"mode" => "command", "command" => "y", "fork" => "copy"}
    }

    filtered = Config.filter_json_for_fork(json)
    # elixir defaults to copy
    assert Map.has_key?(filtered, "elixir_safe")
    # explicit copy overrides default skip
    assert Map.has_key?(filtered, "explicit_copy")
    # sandbox-exec now defaults to skip (may hold external locks)
    refute Map.has_key?(filtered, "sandbox_default")
    # command defaults to skip
    refute Map.has_key?(filtered, "dangerous")
    # explicit skip overrides default copy
    refute Map.has_key?(filtered, "explicit_skip")
  end

  test "fork_behavior defaults" do
    # sandbox-exec defaults to skip (may hold external locks)
    assert Config.fork_behavior(%Config{mode: :sandbox_exec}) == :skip
    # elixir defaults to copy (stateless in-BEAM)
    assert Config.fork_behavior(%Config{mode: :elixir}) == :copy
    assert Config.fork_behavior(%Config{mode: :command}) == :skip
    # explicit override takes precedence
    assert Config.fork_behavior(%Config{mode: :command, fork: :copy}) == :copy
    assert Config.fork_behavior(%Config{mode: :sandbox_exec, fork: :copy}) == :copy
    assert Config.fork_behavior(%Config{mode: :elixir, fork: :skip}) == :skip
  end

  test "filters __processes.json during fork", %{store: store} do
    proc_content =
      Jason.encode!(%{
        "safe_elixir" => %{"mode" => "elixir", "source" => "worker.exs"},
        "copyable" => %{"mode" => "sandbox-exec", "command" => "work", "fork" => "copy"},
        "singleton" => %{"mode" => "command", "command" => "run"}
      })

    proc_uuid = create_text_doc(store, "__processes.json", proc_content)
    file_uuid = create_text_doc(store, "data.txt", "data")

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "__processes.json", proc_uuid)
    root_doc = Schema.add_file(root_doc, "data.txt", file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    {new_root, _manifest} = Fork.fork_directory(root_uuid, store)

    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    {:ok, proc_entry} = Schema.get_entry(doc, "__processes.json")

    {:ok, proc_commit} = CommitStore.latest_commit(store, proc_entry.node_id)
    proc_doc = Yelixer.Doc.new()
    {:ok, proc_doc} = Yelixer.Encoding.apply_update(proc_doc, proc_commit.update)
    content = ContentType.get_content(proc_doc)
    parsed = Jason.decode!(content)

    # elixir (copy default) present
    assert Map.has_key?(parsed, "safe_elixir")
    # explicit fork: copy present
    assert Map.has_key?(parsed, "copyable")
    # command (skip) removed
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
