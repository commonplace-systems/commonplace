defmodule Commonplace.CLI.SnapshotTest do
  @moduledoc """
  Tests for the explicit `commonplace snapshot <path>` command (CX-2ok0).

  Uses the application-default CommitStore so we exercise the same
  CLI.ensure_started + path-resolution path the production CLI runs
  through, without restarting the BEAM app per test.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    # Reuse the running app's CommitStore + its configured data_dir.
    # Each test gets its own root_uuid so they don't interact via the
    # shared store's name index.
    data_dir = Application.get_env(:commonplace, :data_dir) || "tmp/test_data"
    File.mkdir_p!(data_dir)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()

    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "notes.txt")
    doc = ContentType.insert_text(doc, 0, "first")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(CommitStore, file_uuid, update, nil)

    # Chain another commit so the doc has a non-trivial chain to fold.
    doc2 = Yelixer.Doc.new()
    doc2 = ContentType.create(doc2, :text, "notes.txt")
    doc2 = ContentType.insert_text(doc2, 0, "second draft")
    update2 = Yelixer.Encoding.encode_update(doc2)
    CommitStore.create_chained_commit(CommitStore, file_uuid, update2)

    root_doc = Schema.add_file(root_doc, "notes.txt", file_uuid)
    root_update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(CommitStore, root_uuid, root_update, nil)

    # Stash the current root file (if any) and write our test's root
    # into the data_dir so CLI commands' workspace lookup finds it.
    root_file = Path.join(data_dir, "root")
    prior_root = File.exists?(root_file) && File.read!(root_file)
    File.write!(root_file, root_uuid)

    on_exit(fn ->
      case prior_root do
        false -> File.rm(root_file)
        content -> File.write!(root_file, content)
      end
    end)

    %{dir: data_dir, root: root_uuid, file_uuid: file_uuid}
  end

  describe "snapshot command" do
    test "writes a snapshot commit for the resolved doc",
         %{dir: dir, file_uuid: file_uuid} do
      ids_before = CommitStore.all_commit_ids_for_doc(CommitStore, file_uuid)

      ExUnit.CaptureIO.capture_io(fn ->
        Commonplace.CLI.Snapshot.run(dir, "", ["notes.txt"])
      end)

      ids_after = CommitStore.all_commit_ids_for_doc(CommitStore, file_uuid)
      new_ids = MapSet.difference(ids_after, ids_before)
      assert MapSet.size(new_ids) == 1,
             "expected exactly one new commit, got #{MapSet.size(new_ids)}"

      [new_id] = MapSet.to_list(new_ids)
      {:ok, new_commit} = CommitStore.get_commit(CommitStore, new_id)
      assert new_commit.metadata[:kind] == :snapshot,
             "newly-created commit should be a snapshot, got #{inspect(new_commit.metadata)}"
    end

    test "writes a snapshot for the root schema when no path is given",
         %{dir: dir, root: root_uuid} do
      ids_before = CommitStore.all_commit_ids_for_doc(CommitStore, root_uuid)

      ExUnit.CaptureIO.capture_io(fn ->
        Commonplace.CLI.Snapshot.run(dir, "", [])
      end)

      ids_after = CommitStore.all_commit_ids_for_doc(CommitStore, root_uuid)
      new_ids = MapSet.difference(ids_after, ids_before)
      assert MapSet.size(new_ids) == 1

      [new_id] = MapSet.to_list(new_ids)
      {:ok, new_commit} = CommitStore.get_commit(CommitStore, new_id)
      assert new_commit.metadata[:kind] == :snapshot
    end

    # Not-found path resolution → System.halt(1). System.halt terminates
    # the BEAM and can't be caught by ExUnit, so the unresolved-path
    # behavior is exercised at the Walk.resolve_path layer (covered by
    # uuid_test.exs and the broader Walk tests) rather than via direct
    # CLI invocation here.
  end
end
