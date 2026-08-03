defmodule Commonplace.Reflog.CheckoutTest do
  @moduledoc """
  Acceptance tests for the CX-0t2r stage-2 LOCAL CHECKOUT materializer
  (`Commonplace.Reflog.Restore.materialize_dir/4`) and the
  resolver-based diff (`Restore.diff/3`).

  Scope: this suite covers `materialize_dir/4` and `diff/3` only. The
  BRANCH materializer (`materialize_branch/4`) has its own suite in
  `restore_test.exs`; passing this suite says nothing about that path.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Reflog.{Snapshot, Restore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_reflog_checkout_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_reflog_checkout_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    Snapshot.clear_cursor()
    Snapshot.clear_amortization_state()

    dest_root =
      Path.join(System.tmp_dir!(), "cp_reflog_checkout_dest_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(dest_root)

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(dest_root)
    end)

    %{store: store_name, dest_root: dest_root}
  end

  # --- helpers (mirrors restore_test.exs) -----------------------------

  defp create_text_doc(store, name, content, sign_opts \\ []) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil, %{}, sign_opts)
    uuid
  end

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

  # Two checkpoints: C1 = initial seed, C2 = after editing notes.txt and
  # adding added.txt. Returns {ids, checkpoint1_id, checkpoint2_id, snapshot_uuid}.
  defp seed_two_checkpoints(store) do
    ids = seed_tree(store)
    {:ok, _cid1} = Snapshot.checkpoint(ids.root, store)

    write_text_doc(store, ids.notes, "v2 notes")
    added_uuid = create_text_doc(store, "added.txt", "brand new")
    root_schema = load_schema(store, ids.root) |> Schema.add_file("added.txt", added_uuid)
    write_schema(store, ids.root, root_schema)

    {:ok, _cid2} = Snapshot.checkpoint(ids.root, store)

    [{c2, _, _}, {c1, _, _}] = Restore.list_checkpoints(store, ids.root, "server")
    {:ok, snapshot_uuid} = Restore.root_snapshot_uuid(store, ids.root, "server")

    {ids, c1, c2, snapshot_uuid}
  end

  # --- (a) round-trip ---------------------------------------------------

  test "materialize_dir/4 reproduces file contents at each checkpoint, byte-equal", %{
    store: store,
    dest_root: dest_root
  } do
    {_ids, c1, c2, snapshot_uuid} = seed_two_checkpoints(store)

    dest1 = Path.join(dest_root, "at-c1")
    {:ok, resolved1} = Restore.resolve(store, snapshot_uuid, c1)
    {:ok, %{files: n1, dest: ^dest1}} = Restore.materialize_dir(store, resolved1, dest1)

    assert n1 == 3
    assert File.read!(Path.join(dest1, "notes.txt")) == "v1 notes"
    assert File.read!(Path.join(dest1, "keep.txt")) == "never changes"
    assert File.read!(Path.join(dest1, "docs/readme.md")) == "v1 readme"
    refute File.exists?(Path.join(dest1, "added.txt"))

    dest2 = Path.join(dest_root, "at-c2")
    {:ok, resolved2} = Restore.resolve(store, snapshot_uuid, c2)
    {:ok, %{files: n2, dest: ^dest2}} = Restore.materialize_dir(store, resolved2, dest2)

    assert n2 == 4
    assert File.read!(Path.join(dest2, "notes.txt")) == "v2 notes"
    assert File.read!(Path.join(dest2, "keep.txt")) == "never changes"
    assert File.read!(Path.join(dest2, "docs/readme.md")) == "v1 readme"
    assert File.read!(Path.join(dest2, "added.txt")) == "brand new"
  end

  # --- (b) zero-store-writes --------------------------------------------

  test "materialize_dir/4 issues zero store writes", %{store: store, dest_root: dest_root} do
    {_ids, c1, _c2, snapshot_uuid} = seed_two_checkpoints(store)
    {:ok, resolved} = Restore.resolve(store, snapshot_uuid, c1)

    before = total_commit_count(store)
    dest = Path.join(dest_root, "zero-writes")
    {:ok, _} = Restore.materialize_dir(store, resolved, dest)
    afterward = total_commit_count(store)

    assert before == afterward,
           "materialize_dir/4 must not write — commit count changed from #{before} to #{afterward}"
  end

  # --- (c) diff -----------------------------------------------------------

  test "diff/3 shows exactly the mutated/added paths between two checkpoints", %{store: store} do
    {_ids, c1, c2, snapshot_uuid} = seed_two_checkpoints(store)

    {:ok, resolved1} = Restore.resolve(store, snapshot_uuid, c1)
    {:ok, resolved2} = Restore.resolve(store, snapshot_uuid, c2)

    {:ok, diff} = Restore.diff(store, resolved1, {:checkpoint, resolved2})

    assert diff.added == ["added.txt"]
    assert diff.removed == []
    assert diff.changed == [{"notes.txt", :changed}]
  end

  test "diff/3 against current live heads shows the same shape", %{store: store} do
    {ids, c1, _c2, snapshot_uuid} = seed_two_checkpoints(store)

    {:ok, resolved1} = Restore.resolve(store, snapshot_uuid, c1)
    {:ok, diff} = Restore.diff(store, resolved1, {:current, ids.root})

    assert diff.added == ["added.txt"]
    assert diff.removed == []
    assert diff.changed == [{"notes.txt", :changed}]
  end

  test "diff/3 detects same-name-different-doc_uuid as :replaced", %{store: store} do
    ids = seed_tree(store)
    {:ok, _cid1} = Snapshot.checkpoint(ids.root, store)

    # Replace notes.txt's schema entry with a brand-new (unrelated) doc
    # under the SAME name, rather than editing the existing doc.
    replacement_uuid = create_text_doc(store, "notes.txt", "unrelated content")

    root_schema =
      load_schema(store, ids.root)
      |> Schema.add_file("notes.txt", replacement_uuid)

    write_schema(store, ids.root, root_schema)
    {:ok, _cid2} = Snapshot.checkpoint(ids.root, store)

    [{c2, _, _}, {c1, _, _}] = Restore.list_checkpoints(store, ids.root, "server")
    {:ok, snapshot_uuid} = Restore.root_snapshot_uuid(store, ids.root, "server")

    {:ok, resolved1} = Restore.resolve(store, snapshot_uuid, c1)
    {:ok, resolved2} = Restore.resolve(store, snapshot_uuid, c2)

    {:ok, diff} = Restore.diff(store, resolved1, {:checkpoint, resolved2})

    assert diff.changed == [{"notes.txt", :replaced}]
  end

  # --- (d) refusal ----------------------------------------------------

  test "materialize_dir/4 refuses a non-empty dest without :force", %{
    store: store,
    dest_root: dest_root
  } do
    {_ids, c1, _c2, snapshot_uuid} = seed_two_checkpoints(store)
    {:ok, resolved} = Restore.resolve(store, snapshot_uuid, c1)

    dest = Path.join(dest_root, "nonempty")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "unrelated.txt"), "pre-existing")

    before = total_commit_count(store)

    assert {:error, {:dest_not_empty, ^dest}} = Restore.materialize_dir(store, resolved, dest)
    assert total_commit_count(store) == before

    # unrelated content untouched
    assert File.read!(Path.join(dest, "unrelated.txt")) == "pre-existing"
    refute File.exists?(Path.join(dest, "notes.txt"))

    # --force overrides
    {:ok, %{files: n}} = Restore.materialize_dir(store, resolved, dest, force: true)
    assert n == 3
    assert File.read!(Path.join(dest, "notes.txt")) == "v1 notes"
  end

  test "materialize_dir/4 refuses a dest inside a registered checkout", %{
    store: store,
    dest_root: dest_root
  } do
    {_ids, c1, _c2, snapshot_uuid} = seed_two_checkpoints(store)
    {:ok, resolved} = Restore.resolve(store, snapshot_uuid, c1)

    checkout_dir = Path.join(dest_root, "live-checkout")
    File.mkdir_p!(checkout_dir)

    config_path = Path.join(dest_root, "checkouts.json")

    File.write!(
      config_path,
      Jason.encode!([%{"sync_dir" => checkout_dir, "uuid" => UUID.uuid4(), "type" => "dir"}])
    )

    dest = Path.join(checkout_dir, "subdir")

    before = total_commit_count(store)

    assert {:error, {:dest_inside_checkout, checkout}} =
             Restore.materialize_dir(store, resolved, dest, config_path: config_path)

    assert checkout.sync_dir == checkout_dir
    assert total_commit_count(store) == before
    refute File.exists?(dest)

    # A dest outside the registered checkout is unaffected by the same config.
    other_dest = Path.join(dest_root, "unrelated-dest")
    {:ok, %{files: n}} = Restore.materialize_dir(store, resolved, other_dest, config_path: config_path)
    assert n == 3
  end
end
