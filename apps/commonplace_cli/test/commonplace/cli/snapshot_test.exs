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
    # CX-edy test-recovery: pin the app to the default test data_dir
    # regardless of what prior tests may have left in the env. Earlier
    # commonplace tests temporarily `Application.put_env(:commonplace,
    # :data_dir, ...)` for their own fixtures; an interleaved
    # on_exit restore could leave the env pointing at a dir whose
    # CubDB no longer exists. We force a known-good state here so
    # our commits land where CLI.ensure_started will later look.
    data_dir = "tmp/test_data"

    if Application.get_env(:commonplace, :data_dir) != data_dir do
      Application.stop(:commonplace)
      Application.put_env(:commonplace, :data_dir, data_dir)
      {:ok, _} = Application.ensure_all_started(:commonplace)
    end

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

      assert {:ok, commit, ^file_uuid} =
               Commonplace.CLI.Snapshot.do_run(dir, "", ["notes.txt"])

      assert commit.metadata[:kind] == :snapshot

      ids_after = CommitStore.all_commit_ids_for_doc(CommitStore, file_uuid)
      new_ids = MapSet.difference(ids_after, ids_before)

      assert MapSet.size(new_ids) == 1,
             "expected exactly one new commit, got #{MapSet.size(new_ids)}"
    end

    test "writes a snapshot for the root schema when no path is given",
         %{dir: dir, root: root_uuid} do
      ids_before = CommitStore.all_commit_ids_for_doc(CommitStore, root_uuid)

      assert {:ok, commit, ^root_uuid} =
               Commonplace.CLI.Snapshot.do_run(dir, "", [])

      assert commit.metadata[:kind] == :snapshot

      ids_after = CommitStore.all_commit_ids_for_doc(CommitStore, root_uuid)
      new_ids = MapSet.difference(ids_after, ids_before)
      assert MapSet.size(new_ids) == 1
    end

    # CX-edy test-recovery: do_run/3 returns structured errors instead
    # of calling System.halt/1. That lets tests assert the unresolved-
    # path behavior directly without terminating the BEAM (previously
    # a stale workspace root file in shared `tmp/test_data` would halt
    # the whole test suite mid-run). The `run/3` wrapper keeps halt
    # semantics for real CLI invocation.
    test "returns :path_not_found when the path does not resolve",
         %{dir: dir} do
      assert {:error, {:path_not_found, "ghost.txt"}} =
               Commonplace.CLI.Snapshot.do_run(dir, "", ["ghost.txt"])
    end
  end
end
