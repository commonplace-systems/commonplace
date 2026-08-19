defmodule Commonplace.Tree.ForkAtTest do
  @moduledoc """
  CX-65n: time-travel checkout. `Fork.fork_directory_at/3` reconstructs
  the tree at a specific historical commit (identified by its
  commit_id in the root's chain) and deep-copies with new UUIDs.

  Uses the root commit's timestamp as the reference time for each
  sub-document: a child's state is taken from its last commit whose
  timestamp is <= reference time. This gives a snapshot-consistent
  view across independent document chains.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Tree.{Fork, DocBuilder, Schema}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Yelixer.{Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_fork_at_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"fork_at_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp create_text_doc(store, uuid, content) do
    doc = Doc.new()
    doc = ContentType.create(doc, :text, "doc")
    doc = ContentType.insert_text(doc, 0, content)
    update = Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp modify_text_doc(store, uuid, new_content) do
    # Create a new commit with the replacement content. Need a small
    # time delta so timestamps can be compared.
    Process.sleep(5)
    doc = Doc.new()
    doc = ContentType.create(doc, :text, "doc")
    doc = ContentType.insert_text(doc, 0, new_content)
    update = Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update)
  end

  defp create_schema_with_files(store, root_uuid, files) do
    # files = [{name, child_uuid}, ...]
    schema =
      Enum.reduce(files, Schema.new_schema(), fn {name, uuid}, acc ->
        Schema.add_file(acc, name, uuid)
      end)

    update = Encoding.encode_update(schema)
    CommitStore.create_commit(store, root_uuid, update, nil)
  end

  defp content_at(store, uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  # Decode a schema doc — must start from Schema.new_schema() to have
  # :map types registered (mirrors the pattern used in fork_test.exs).
  # DocBuilder.reconstruct_doc starts from Doc.new() which leaves type
  # names as :unknown and causes YMap ops to silently no-op.
  defp schema_at(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    schema = Schema.new_schema()
    {:ok, schema} = Encoding.apply_update(schema, commit.update)
    schema
  end

  describe "fork_directory_at/3" do
    test "fork at a historical root commit captures the child state at that time",
         %{store: store} do
      root = UUID.uuid4()
      child = UUID.uuid4()

      create_text_doc(store, child, "v1")
      root_commit = create_schema_with_files(store, root, [{"c.txt", child}])

      # Later: change the child and add a sibling.
      modify_text_doc(store, child, "v2")
      Process.sleep(5)
      sibling = UUID.uuid4()
      create_text_doc(store, sibling, "added-later")

      {:ok, updated_schema} = DocBuilder.reconstruct_doc(store, root)
      updated_schema = Schema.add_file(updated_schema, "s.txt", sibling)
      update = Encoding.encode_update(updated_schema)
      CommitStore.create_chained_commit(store, root, update)

      # Fork at the ORIGINAL root commit — sibling doesn't exist yet, child is v1.
      {:ok, new_root} = Fork.fork_directory_at(root, root_commit.id, store)

      new_schema = schema_at(store, new_root)
      names = Schema.list_entries(new_schema) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["c.txt"]

      {:ok, c_entry} = Schema.get_entry(new_schema, "c.txt")
      assert c_entry.node_id != child, "child must have a NEW uuid in the fork"
      assert content_at(store, c_entry.node_id) == "v1"
    end

    test "fork at latest root commit matches normal fork_directory behavior",
         %{store: store} do
      root = UUID.uuid4()
      child = UUID.uuid4()

      create_text_doc(store, child, "hello")
      root_commit = create_schema_with_files(store, root, [{"c.txt", child}])

      {:ok, new_root} = Fork.fork_directory_at(root, root_commit.id, store)

      new_schema = schema_at(store, new_root)
      {:ok, c_entry} = Schema.get_entry(new_schema, "c.txt")
      assert content_at(store, c_entry.node_id) == "hello"
    end

    test "returns error when target_commit_id is not in root's chain",
         %{store: store} do
      root = UUID.uuid4()
      create_text_doc(store, UUID.uuid4(), "noise")
      create_schema_with_files(store, root, [])

      bogus = :crypto.hash(:sha256, "not-a-real-commit")
      assert {:error, _reason} = Fork.fork_directory_at(root, bogus, store)
    end

    test "deep-copy uses new UUIDs distinct from source", %{store: store} do
      root = UUID.uuid4()
      child_a = UUID.uuid4()
      child_b = UUID.uuid4()

      create_text_doc(store, child_a, "a")
      create_text_doc(store, child_b, "b")

      root_commit =
        create_schema_with_files(store, root, [{"a.txt", child_a}, {"b.txt", child_b}])

      {:ok, new_root} = Fork.fork_directory_at(root, root_commit.id, store)
      assert new_root != root

      new_schema = schema_at(store, new_root)
      {:ok, new_a} = Schema.get_entry(new_schema, "a.txt")
      {:ok, new_b} = Schema.get_entry(new_schema, "b.txt")

      assert new_a.node_id not in [child_a, child_b]
      assert new_b.node_id not in [child_a, child_b]
      assert new_a.node_id != new_b.node_id
    end
  end
end
