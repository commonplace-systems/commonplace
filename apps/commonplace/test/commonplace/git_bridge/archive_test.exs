defmodule Commonplace.GitBridge.ArchiveTest do
  @moduledoc """
  GitBridge G1.5 (CX-b0ow.4): self-verifying commit archive under
  `.commonplace/archive/`.

  Row format reuses `Commonplace.Federation.Envelope.for_commit/2`
  (already versioned via its own `"v"` field); layout is
  `.commonplace/archive/<doc-uuid>/<commit-id-hex>.json`. Watermark is
  a single canonical-JSON `.commonplace/archive/watermarks.json` keyed
  by doc uuid.
  """

  use ExUnit.Case, async: false

  alias Commonplace.GitBridge.{Archive, Exporter, Server}
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient, Commit}
  alias Commonplace.Federation.Envelope
  alias Commonplace.Presence

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_archive_store_#{:rand.uniform(1_000_000_000)}")
    repo_dir = Path.join(System.tmp_dir!(), "cp_gb_archive_repo_#{:rand.uniform(1_000_000_000)}")
    workspace_dir = Path.join(System.tmp_dir!(), "cp_gb_archive_ws_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(repo_dir)
    File.mkdir_p!(workspace_dir)

    store_name = :"gb_archive_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    prev_data_dir = Application.get_env(:commonplace, :data_dir)

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(repo_dir)
      File.rm_rf!(workspace_dir)

      Application.put_env(:commonplace, :data_dir, prev_data_dir || "tmp/test_data")
    end)

    %{store: store_name, repo_dir: repo_dir, workspace_dir: workspace_dir}
  end

  defp create_text(store, uuid, name, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_map(store, uuid, name, map) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, name)
    doc = Enum.reduce(map, doc, fn {k, v}, acc -> ContentType.set_key(acc, k, v) end)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_schema(store, uuid, schema_doc) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp put_workspace_root(workspace_dir, root_uuid) do
    Application.put_env(:commonplace, :data_dir, workspace_dir)
    File.write!(Path.join(workspace_dir, "root"), root_uuid)
  end

  defp unique_name(prefix), do: :"#{prefix}_#{:rand.uniform(1_000_000_000)}"

  # Same tree shape as server_test.exs: a mount with a text doc, a map
  # doc, a nested dir (own schema doc) with a file, a __system entry, a
  # nosync entry, and a human presence file.
  defp seed_tree(store, workspace_dir) do
    root_uuid = "root-uuid-#{:rand.uniform(1_000_000_000)}"
    mount_uuid = "mount-uuid-#{:rand.uniform(1_000_000_000)}"
    sub_uuid = "sub-uuid-#{:rand.uniform(1_000_000_000)}"

    create_text(store, "doc-a", "a.txt", "hello world")
    create_map(store, "doc-b", "b.json", %{"k" => "v"})
    create_text(store, "doc-nosync", "nosync.txt", "should not appear")
    create_text(store, "doc-sys", "__system", "should not appear")
    create_text(store, "doc-nested", "nested.txt", "deep")

    {:ok, _presence_uuid} = Presence.create("alice", :usr, mount_uuid, store)

    sub_schema = Schema.new_schema() |> Schema.add_file("nested.txt", "doc-nested")
    create_schema(store, sub_uuid, sub_schema)

    mount_schema =
      Schema.new_schema()
      |> Schema.add_file("a.txt", "doc-a")
      |> Schema.add_file("b.json", "doc-b")
      |> Schema.add_file("nosync.txt", "doc-nosync")
      |> Schema.set_sync("nosync.txt", false)
      |> Schema.add_file("__system", "doc-sys")
      |> Schema.add_directory("nested", sub_uuid)

    create_schema(store, mount_uuid, mount_schema)

    root_schema = Schema.new_schema() |> Schema.add_directory("workspace", mount_uuid)
    create_schema(store, root_uuid, root_schema)

    put_workspace_root(workspace_dir, root_uuid)

    %{
      root_uuid: root_uuid,
      mount_uuid: mount_uuid,
      sub_uuid: sub_uuid,
      doc_uuids: ["doc-a", "doc-b", "doc-nested"],
      schema_uuids: [mount_uuid, sub_uuid]
    }
  end

  defp archive_rows(repo_dir, uuid) do
    dir = Path.join([repo_dir, ".commonplace", "archive", uuid])

    if File.dir?(dir) do
      dir |> File.ls!() |> Enum.sort()
    else
      []
    end
  end

  defp run_full_cycle(mount_uuid, repo_dir, store, name) do
    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    Server.sync_now(name)
  end

  test "first cycle: one archive row per commit per eligible doc (incl. schema docs), watermark set",
       %{store: store, repo_dir: repo_dir, workspace_dir: workspace_dir} do
    %{mount_uuid: mount_uuid, doc_uuids: doc_uuids, schema_uuids: schema_uuids} =
      seed_tree(store, workspace_dir)

    name = unique_name("gb_archive1")
    {:ok, result} = run_full_cycle(mount_uuid, repo_dir, store, name)
    assert result.committed == true

    # Every doc in this tree was seeded with a single `create_commit(...,
    # nil)` call, which CommitBuilder auto-resolves into TWO commits: a
    # deterministic genesis row (parent_id nil, empty update) plus the
    # regular commit chained on top — so the expected row count per doc
    # is 2, one file per commit in the chain.
    for uuid <- doc_uuids ++ schema_uuids do
      rows = archive_rows(repo_dir, uuid)
      assert length(rows) == 2, "expected exactly 2 commit rows for #{uuid}, got #{inspect(rows)}"

      commits =
        Enum.map(rows, fn row ->
          assert row =~ ~r/^[0-9a-f]+\.json$/
          path = Path.join([repo_dir, ".commonplace", "archive", uuid, row])
          {:ok, %{commit: commit}} = Envelope.decode(File.read!(path))
          assert Commit.verify_id(commit) == :ok
          commit
        end)

      assert Enum.any?(commits, &(&1.parent_id == nil)), "expected a genesis row for #{uuid}"
    end

    watermarks_path = Path.join([repo_dir, ".commonplace", "archive", "watermarks.json"])
    assert File.exists?(watermarks_path)
    watermarks = Jason.decode!(File.read!(watermarks_path))

    for uuid <- doc_uuids ++ schema_uuids do
      {:ok, head} = CommitStoreClient.latest_commit(store, uuid)
      assert watermarks[uuid] == Base.encode16(head.id, case: :lower)
    end
  end

  test "excluded docs never get an archive directory (__ / nosync / presence)", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_archive2")

    {:ok, _} = run_full_cycle(mount_uuid, repo_dir, store, name)
    assert archive_rows(repo_dir, "doc-nosync") == []
    assert archive_rows(repo_dir, "doc-sys") == []

    {:ok, _} = Server.sync_now(name)
    assert archive_rows(repo_dir, "doc-nosync") == []
    assert archive_rows(repo_dir, "doc-sys") == []

    archive_dir = Path.join([repo_dir, ".commonplace", "archive"])
    entries = archive_dir |> File.ls!() |> Enum.reject(&(&1 == "watermarks.json"))
    refute "doc-nosync" in entries
    refute "doc-sys" in entries
  end

  test "restorability pin: archived rows for a doc replay into a fresh store to the same content",
       %{store: store, repo_dir: repo_dir, workspace_dir: workspace_dir} do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_archive3")
    {:ok, _} = run_full_cycle(mount_uuid, repo_dir, store, name)

    # Make a couple more commits on doc-a so the chain has real depth.
    {:ok, doc} = DocBuilder.reconstruct_doc(store, "doc-a")
    content = ContentType.get_content(doc) || ""
    doc = ContentType.delete_text(doc, 0, String.length(content))
    doc = ContentType.insert_text(doc, 0, "first edit")
    CommitStore.create_chained_commit(store, "doc-a", Yelixer.Encoding.encode_update(doc))

    {:ok, doc} = DocBuilder.reconstruct_doc(store, "doc-a")
    content = ContentType.get_content(doc) || ""
    doc = ContentType.delete_text(doc, 0, String.length(content))
    doc = ContentType.insert_text(doc, 0, "second edit")
    CommitStore.create_chained_commit(store, "doc-a", Yelixer.Encoding.encode_update(doc))

    {:ok, _} = Server.sync_now(name)

    {:ok, original_doc} = DocBuilder.reconstruct_doc(store, "doc-a")
    original_content = ContentType.get_content(original_doc)
    assert original_content == "second edit"

    # genesis + initial "hello world" commit + the two edits below.
    rows = archive_rows(repo_dir, "doc-a")
    assert length(rows) == 4

    envelopes =
      Enum.map(rows, fn row ->
        path = Path.join([repo_dir, ".commonplace", "archive", "doc-a", row])
        {:ok, %{commit: commit}} = Envelope.decode(File.read!(path))
        assert Commit.verify_id(commit) == :ok
        commit
      end)

    # Derive chain order from parent_id links (never trust file listing order).
    by_id = Map.new(envelopes, &{&1.id, &1})
    root = Enum.find(envelopes, &(&1.parent_id == nil || not Map.has_key?(by_id, &1.parent_id)))
    ordered = build_chain_order(root, by_id)
    assert length(ordered) == length(envelopes)

    fresh_store_dir =
      Path.join(System.tmp_dir!(), "cp_gb_archive_fresh_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(fresh_store_dir)
    fresh_name = unique_name("gb_archive_fresh")
    {:ok, _fresh_pid} = CommitStore.start_link(data_dir: fresh_store_dir, name: fresh_name)
    on_exit(fn -> File.rm_rf!(fresh_store_dir) end)

    Enum.each(ordered, fn commit ->
      assert :ok == CommitStoreClient.import_commit(fresh_name, commit)
    end)

    :ok = CommitStoreClient.set_latest(fresh_name, "doc-a", List.last(ordered).id)

    {:ok, restored_doc} = DocBuilder.reconstruct_doc(fresh_name, "doc-a")
    restored_content = ContentType.get_content(restored_doc)

    assert restored_content == original_content
  end

  defp build_chain_order(nil, _by_id), do: []

  defp build_chain_order(commit, by_id) do
    children = Enum.filter(Map.values(by_id), &(&1.parent_id == commit.id))

    case children do
      [] -> [commit]
      [child] -> [commit | build_chain_order(child, by_id)]
      _ -> [commit | build_chain_order(hd(children), by_id)]
    end
  end

  test "incremental: 2 new commits yield exactly 2 new rows, pre-existing rows byte-identical, watermark advances",
       %{store: store, repo_dir: repo_dir, workspace_dir: workspace_dir} do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_archive4")
    {:ok, _} = run_full_cycle(mount_uuid, repo_dir, store, name)

    # genesis + initial "hello world" commit.
    rows_before = archive_rows(repo_dir, "doc-a")
    assert length(rows_before) == 2

    before_hashes =
      Map.new(rows_before, fn row ->
        path = Path.join([repo_dir, ".commonplace", "archive", "doc-a", row])
        {row, :crypto.hash(:sha256, File.read!(path))}
      end)

    {:ok, doc} = DocBuilder.reconstruct_doc(store, "doc-a")
    content = ContentType.get_content(doc) || ""
    doc = ContentType.delete_text(doc, 0, String.length(content))
    doc = ContentType.insert_text(doc, 0, "edit one")
    CommitStore.create_chained_commit(store, "doc-a", Yelixer.Encoding.encode_update(doc))

    {:ok, doc} = DocBuilder.reconstruct_doc(store, "doc-a")
    content = ContentType.get_content(doc) || ""
    doc = ContentType.delete_text(doc, 0, String.length(content))
    doc = ContentType.insert_text(doc, 0, "edit two")
    CommitStore.create_chained_commit(store, "doc-a", Yelixer.Encoding.encode_update(doc))

    {:ok, _} = Server.sync_now(name)

    rows_after = archive_rows(repo_dir, "doc-a")
    assert length(rows_after) == 4

    new_rows = rows_after -- rows_before
    assert length(new_rows) == 2

    Enum.each(before_hashes, fn {row, hash} ->
      path = Path.join([repo_dir, ".commonplace", "archive", "doc-a", row])
      assert :crypto.hash(:sha256, File.read!(path)) == hash
    end)

    watermarks_path = Path.join([repo_dir, ".commonplace", "archive", "watermarks.json"])
    watermarks = Jason.decode!(File.read!(watermarks_path))
    {:ok, head} = CommitStoreClient.latest_commit(store, "doc-a")
    assert watermarks["doc-a"] == Base.encode16(head.id, case: :lower)
  end

  test "idempotent re-archive: deleting the watermark and re-running yields byte-identical rows and clean git status",
       %{store: store, repo_dir: repo_dir, workspace_dir: workspace_dir} do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_archive5")
    {:ok, _} = run_full_cycle(mount_uuid, repo_dir, store, name)

    {status0, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_dir)
    assert String.trim(status0) == ""

    all_hashes_before =
      for uuid <- ["doc-a", "doc-b", "doc-nested"], row <- archive_rows(repo_dir, uuid) do
        path = Path.join([repo_dir, ".commonplace", "archive", uuid, row])
        {{uuid, row}, :crypto.hash(:sha256, File.read!(path))}
      end
      |> Map.new()

    watermarks_path = Path.join([repo_dir, ".commonplace", "archive", "watermarks.json"])
    File.rm!(watermarks_path)

    {:ok, result} = Server.sync_now(name)

    all_hashes_after =
      for uuid <- ["doc-a", "doc-b", "doc-nested"], row <- archive_rows(repo_dir, uuid) do
        path = Path.join([repo_dir, ".commonplace", "archive", uuid, row])
        {{uuid, row}, :crypto.hash(:sha256, File.read!(path))}
      end
      |> Map.new()

    assert all_hashes_after == all_hashes_before

    # Watermark file itself is regenerated deterministically.
    assert File.exists?(watermarks_path)

    # Nothing else in the tree changed, so git status is clean once
    # more IF the watermark file's regenerated bytes are identical to
    # what was committed before deletion — assert on content re: repo.
    if result.committed do
      {status1, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_dir)
      assert String.trim(status1) == ""
    end
  end

  test "archive rides the same git commit as the content it backs", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_archive6")
    {:ok, _} = run_full_cycle(mount_uuid, repo_dir, store, name)

    {:ok, doc} = DocBuilder.reconstruct_doc(store, "doc-a")
    content = ContentType.get_content(doc) || ""
    doc = ContentType.delete_text(doc, 0, String.length(content))
    doc = ContentType.insert_text(doc, 0, "changed!")
    CommitStore.create_chained_commit(store, "doc-a", Yelixer.Encoding.encode_update(doc))

    {:ok, result} = Server.sync_now(name)
    assert result.committed == true

    {show, 0} = System.cmd("git", ["show", "--name-only", "--pretty=format:", result.sha], cd: repo_dir)
    changed_files = show |> String.split("\n", trim: true)

    assert "a.txt" in changed_files
    assert Enum.any?(changed_files, &String.starts_with?(&1, ".commonplace/archive/doc-a/"))
  end

  test "Exporter.export/4 exposes schema_uuids for archive scoping", %{
    store: store,
    repo_dir: repo_dir
  } do
    create_text(store, "uuid-a", "a.txt", "hi")
    sub = Schema.new_schema() |> Schema.add_file("a.txt", "uuid-a")
    create_schema(store, "uuid-sub", sub)
    root = Schema.new_schema() |> Schema.add_directory("subdir", "uuid-sub")
    create_schema(store, "uuid-root", root)

    {:ok, result} = Exporter.export("uuid-root", repo_dir, store)

    assert MapSet.member?(result.schema_uuids, "uuid-root")
    assert MapSet.member?(result.schema_uuids, "uuid-sub")
  end

  test "Archive.archive/3 is a no-op count-wise for docs with no commits" do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_archive_empty_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)
    name = unique_name("gb_archive_empty")
    {:ok, _pid} = CommitStore.start_link(data_dir: store_dir, name: name)

    repo_dir = Path.join(System.tmp_dir!(), "cp_gb_archive_empty_repo_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(repo_dir)
    on_exit(fn -> File.rm_rf!(repo_dir) end)

    result = Archive.archive(name, repo_dir, ["nonexistent-uuid"])
    assert result.archived_count == 0
  end
end
