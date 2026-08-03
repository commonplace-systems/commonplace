defmodule Commonplace.Reflog.RestoreTest do
  @moduledoc """
  Acceptance tests for `Commonplace.Reflog.Restore` — the RESTORE half of
  CX-0t2r.

  Scope: this suite covers the BRANCH materializer
  (`materialize_branch/4`) only, exercised through the public
  `list_checkpoints/3` -> `resolve/3` -> `materialize_branch/4` pipeline.
  `materialize_branch/4` is structurally refused unless called with
  `unsafe_no_ancestry: true` (fresh-genesis restores have no shared
  ancestry with their source docs — CX-0t2r stage 3 replaces this with
  fork-anchored materialization); the round-trip/enforce tests below
  pass that escape hatch deliberately, because they exist to exercise
  the resolve/materialize plumbing, not to bless fresh-genesis restore
  as production-ready. The DIRECTORY materializer
  (`Restore.materialize_dir/4`) and `Restore.diff/3` have their own
  suite in `checkout_test.exs`. A future in-place-reroot materializer
  (see the module's moduledoc) needs its own acceptance tests too;
  passing this suite says nothing about either path.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Reflog.{Snapshot, Restore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType
  alias Commonplace.Crypto.NodeIdentity

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_reflog_restore_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_reflog_restore_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    Snapshot.clear_cursor()
    Snapshot.clear_amortization_state()
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  # --- helpers -------------------------------------------------------

  defp create_text_doc(store, name, content, sign_opts \\ []) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil, %{}, sign_opts)
    uuid
  end

  # A real text EDIT: reconstruct the doc's existing chain-replayed state
  # and mutate that (delete-all + insert), rather than building an
  # unrelated fresh doc — a fresh doc's insert-at-0 has origin `nil`, so
  # chain-replaying it after the prior content PREPENDS instead of
  # replacing (Yjs text semantics), which is not what "edit a file" means.
  defp write_text_doc(store, uuid, content, sign_opts \\ []) do
    {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, uuid)
    old_content = ContentType.get_content(doc) || ""
    doc = if old_content != "", do: ContentType.delete_text(doc, 0, String.length(old_content)), else: doc
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update, %{}, sign_opts)
  end

  defp write_schema(store, uuid, schema_doc, sign_opts \\ []) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_chained_commit(store, uuid, update, %{}, sign_opts)
  end

  defp load_schema(store, uuid) do
    case Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp read_text(store, uuid) do
    case Commonplace.Tree.DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  # Recursively read a materialized tree back into a flat
  # %{"path/to/file" => content} map, for round-trip comparison.
  defp read_tree(store, dir_uuid, prefix \\ "") do
    schema = load_schema(store, dir_uuid)

    Schema.list_entries(schema)
    |> Enum.reduce(%{}, fn entry, acc ->
      path = if prefix == "", do: entry.name, else: prefix <> "/" <> entry.name

      case entry.type do
        :doc -> Map.put(acc, path, read_text(store, entry.node_id))
        :dir -> Map.merge(acc, read_tree(store, entry.node_id, path))
      end
    end)
  end

  defp restored_root_uuid(store, workspace_root, branch_name) do
    schema = load_schema(store, workspace_root)
    {:ok, entry} = Schema.get_entry(schema, branch_name)
    entry.node_id
  end

  defp total_commit_count(store) do
    CommitStore.all_doc_uuids(store)
    |> Enum.reduce(0, fn uuid, acc ->
      acc + length(CommitStore.commit_log(store, uuid, limit: 10_000))
    end)
  end

  # Seeds root/notes.txt, root/keep.txt, root/docs/readme.md
  defp seed_tree(store, sign_opts \\ []) do
    notes_uuid = create_text_doc(store, "notes.txt", "v1 notes", sign_opts)
    keep_uuid = create_text_doc(store, "keep.txt", "never changes", sign_opts)
    readme_uuid = create_text_doc(store, "readme.md", "v1 readme", sign_opts)

    docs_uuid = UUID.uuid4()
    docs_schema = Schema.new_schema() |> Schema.add_file("readme.md", readme_uuid)
    write_schema(store, docs_uuid, docs_schema, sign_opts)

    root_uuid = UUID.uuid4()

    root_schema =
      Schema.new_schema()
      |> Schema.add_file("notes.txt", notes_uuid)
      |> Schema.add_file("keep.txt", keep_uuid)
      |> Schema.add_directory("docs", docs_uuid)

    write_schema(store, root_uuid, root_schema, sign_opts)

    %{root: root_uuid, notes: notes_uuid, keep: keep_uuid, docs: docs_uuid, readme: readme_uuid}
  end

  # --- (a) round-trip --------------------------------------------------

  test "round-trip: resolve+materialize reproduces tree state at each checkpoint", %{
    store: store
  } do
    ids = seed_tree(store)

    {:ok, _cid1} = Snapshot.checkpoint(ids.root, store)

    # Mutate: edit notes.txt, add a new file
    write_text_doc(store, ids.notes, "v2 notes")
    added_uuid = create_text_doc(store, "added.txt", "brand new")
    root_schema = load_schema(store, ids.root) |> Schema.add_file("added.txt", added_uuid)
    write_schema(store, ids.root, root_schema)

    {:ok, _cid2} = Snapshot.checkpoint(ids.root, store)

    checkpoints = Restore.list_checkpoints(store, ids.root, "server")
    assert length(checkpoints) == 2

    [{newest_id, _ts_new, _}, {oldest_id, _ts_old, _}] = checkpoints

    {:ok, snapshot_uuid} = Restore.root_snapshot_uuid(store, ids.root, "server")

    # --- restore the FIRST (oldest) checkpoint ---
    {:ok, resolved1} = Restore.resolve(store, snapshot_uuid, oldest_id)
    {:ok, %{root_entry: name1, docs: docs1}} =
      Restore.materialize_branch(store, resolved1, ids.root, as: "restore-v1", unsafe_no_ancestry: true)

    assert docs1 > 0
    restored1_root = restored_root_uuid(store, ids.root, name1)
    tree1 = read_tree(store, restored1_root)

    assert tree1["notes.txt"] == "v1 notes"
    assert tree1["keep.txt"] == "never changes"
    assert tree1["docs/readme.md"] == "v1 readme"
    refute Map.has_key?(tree1, "added.txt")

    # --- restore the SECOND (newest) checkpoint ---
    {:ok, resolved2} = Restore.resolve(store, snapshot_uuid, newest_id)

    {:ok, %{root_entry: name2}} =
      Restore.materialize_branch(store, resolved2, ids.root, as: "restore-v2", unsafe_no_ancestry: true)

    restored2_root = restored_root_uuid(store, ids.root, name2)
    tree2 = read_tree(store, restored2_root)

    assert tree2["notes.txt"] == "v2 notes"
    assert tree2["keep.txt"] == "never changes"
    assert tree2["docs/readme.md"] == "v1 readme"
    assert tree2["added.txt"] == "brand new"
  end

  # --- (b) enforce mode ------------------------------------------------

  describe "under local_write_gate: :enforce" do
    setup %{store: store} do
      old = %{
        trust: Application.get_env(:commonplace, :trust),
        gate: Application.get_env(:commonplace, :local_write_gate),
        data_dir: Application.get_env(:commonplace, :data_dir)
      }

      # NodeIdentity mints/reads its keypair under :commonplace, :data_dir —
      # give it a private scratch dir for this test (mirrors
      # presence_signing_test's setup idiom).
      key_dir =
        Path.join(System.tmp_dir!(), "cp_reflog_restore_enforce_#{:rand.uniform(1_000_000_000)}")

      File.mkdir_p!(key_dir)
      Application.put_env(:commonplace, :data_dir, key_dir)
      Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
      Application.put_env(:commonplace, :local_write_gate, :enforce)

      {:ok, node_ctx} = NodeIdentity.signing_context()

      on_exit(fn ->
        for {k, v} <- old do
          key = %{trust: :trust, gate: :local_write_gate, data_dir: :data_dir}[k]
          if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
        end

        File.rm_rf!(key_dir)
      end)

      %{store: store, node_ctx: node_ctx}
    end

    test "round-trip lands node-signed under strict/enforce (CX-cl65 lesson)", %{
      store: store,
      node_ctx: node_ctx
    } do
      sign_opts = [signing_context: node_ctx]
      ids = seed_tree(store, sign_opts)

      {:ok, _cid} = Snapshot.checkpoint(ids.root, store)

      {:ok, snapshot_uuid} = Restore.root_snapshot_uuid(store, ids.root, "server")
      [{checkpoint_id, _ts, _signer}] = Restore.list_checkpoints(store, ids.root, "server")
      assert checkpoint_id != nil

      {:ok, resolved} = Restore.resolve(store, snapshot_uuid, checkpoint_id)

      {:ok, %{root_entry: name, docs: docs}} =
        Restore.materialize_branch(store, resolved, ids.root, as: "restore-enforce", unsafe_no_ancestry: true)

      assert docs > 0

      restored_root = restored_root_uuid(store, ids.root, name)
      tree = read_tree(store, restored_root)
      assert tree["notes.txt"] == "v1 notes"
      assert tree["docs/readme.md"] == "v1 readme"

      # The new root's own attach-commit on the workspace root landed
      # (which it could only do if it was signed and passed the gate) —
      # confirm it carries a signer_id, not an unsigned commit.
      {:ok, root_commit} = CommitStore.latest_commit(store, ids.root)
      assert root_commit.signer_id != nil
    end
  end

  # --- (c) resolve is read-only (the seam) ------------------------------

  # --- (d) materialize_branch is structurally refused without the escape hatch ---

  test "materialize_branch/4 refuses fresh-genesis materialization by default", %{store: store} do
    ids = seed_tree(store)
    {:ok, _cid} = Snapshot.checkpoint(ids.root, store)

    {:ok, snapshot_uuid} = Restore.root_snapshot_uuid(store, ids.root, "server")
    [{checkpoint_id, _ts, _signer}] = Restore.list_checkpoints(store, ids.root, "server")
    {:ok, resolved} = Restore.resolve(store, snapshot_uuid, checkpoint_id)

    before = total_commit_count(store)

    assert {:error, {:awaiting_stage3_ancestry_rework, "CX-0t2r"}} =
             Restore.materialize_branch(store, resolved, ids.root)

    assert total_commit_count(store) == before,
           "refused materialize_branch/4 must not write either"
  end

  test "resolve/3 performs zero writes", %{store: store} do
    ids = seed_tree(store)
    {:ok, _cid} = Snapshot.checkpoint(ids.root, store)

    {:ok, snapshot_uuid} = Restore.root_snapshot_uuid(store, ids.root, "server")
    [{checkpoint_id, _ts, _signer}] = Restore.list_checkpoints(store, ids.root, "server")

    before = total_commit_count(store)
    {:ok, _resolved} = Restore.resolve(store, snapshot_uuid, checkpoint_id)
    afterward = total_commit_count(store)

    assert before == afterward,
           "resolve/3 must not write — commit count changed from #{before} to #{afterward}"
  end
end
