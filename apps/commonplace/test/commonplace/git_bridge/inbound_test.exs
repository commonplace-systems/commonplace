defmodule Commonplace.GitBridge.InboundTest do
  @moduledoc """
  CX-b0ow.2 (G2): inbound git -> CRDT ingestion, end-to-end through
  `GitBridge.Server`'s real cycle (fetch/ingest -> export -> sidecar ->
  archive -> commit -> push) against a local bare repo ("origin") and a
  second clone simulating a human editor, per the test-pin list in the
  design brief.
  """
  use ExUnit.Case, async: false

  alias Commonplace.GitBridge.Server
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Dataflow.PubSub
  alias Commonplace.GitBridge.CanonicalXml
  alias Yelixer.Types.{XMLFragment, XMLElement, XMLText}

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_in_store_#{:rand.uniform(1_000_000_000)}")
    repo_dir = Path.join(System.tmp_dir!(), "cp_gb_in_repo_#{:rand.uniform(1_000_000_000)}")
    workspace_dir = Path.join(System.tmp_dir!(), "cp_gb_in_ws_#{:rand.uniform(1_000_000_000)}")
    bare_dir = Path.join(System.tmp_dir!(), "cp_gb_in_bare_#{:rand.uniform(1_000_000_000)}")
    clone_dir = Path.join(System.tmp_dir!(), "cp_gb_in_clone_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(store_dir)
    File.mkdir_p!(repo_dir)
    File.mkdir_p!(workspace_dir)
    File.mkdir_p!(bare_dir)

    {_, 0} = System.cmd("git", ["init", "--bare", bare_dir])

    store_name = :"gb_in_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    prev_data_dir = Application.get_env(:commonplace, :data_dir)

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(repo_dir)
      File.rm_rf!(workspace_dir)
      File.rm_rf!(bare_dir)
      File.rm_rf!(clone_dir)

      if prev_data_dir do
        Application.put_env(:commonplace, :data_dir, prev_data_dir)
      else
        Application.delete_env(:commonplace, :data_dir)
      end
    end)

    %{store: store_name, repo_dir: repo_dir, workspace_dir: workspace_dir, bare_dir: bare_dir, clone_dir: clone_dir}
  end

  # --- Seed helpers (mirrors server_test.exs patterns) ---

  defp create_text(store, uuid, name, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_xml_outline(store, uuid, name) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :xml, name)
    doc = XMLFragment.insert_child(doc, "content", 0, {:element, "item"})
    [{:element, _, item_name}] = XMLFragment.to_list(doc, "content")
    doc = XMLElement.insert_child(doc, item_name, 0, :text)
    [{:text, text_name}] = XMLElement.children(doc, item_name)
    doc = XMLText.insert(doc, text_name, 0, "first bullet")
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

  defp seed_single_doc(store, workspace_dir, content) do
    root_uuid = "root-#{:rand.uniform(1_000_000_000)}"
    mount_uuid = "mount-#{:rand.uniform(1_000_000_000)}"
    doc_uuid = "doc-#{:rand.uniform(1_000_000_000)}"

    create_text(store, doc_uuid, "a.txt", content)

    mount_schema = Schema.new_schema() |> Schema.add_file("a.txt", doc_uuid)
    create_schema(store, mount_uuid, mount_schema)

    root_schema = Schema.new_schema() |> Schema.add_directory("workspace", mount_uuid)
    create_schema(store, root_uuid, root_schema)

    put_workspace_root(workspace_dir, root_uuid)

    %{root_uuid: root_uuid, mount_uuid: mount_uuid, doc_uuid: doc_uuid}
  end

  defp seed_xml_doc(store, workspace_dir) do
    root_uuid = "root-#{:rand.uniform(1_000_000_000)}"
    mount_uuid = "mount-#{:rand.uniform(1_000_000_000)}"
    doc_uuid = "doc-#{:rand.uniform(1_000_000_000)}"

    create_xml_outline(store, doc_uuid, "_outline")

    mount_schema = Schema.new_schema() |> Schema.add_file("_outline", doc_uuid)
    create_schema(store, mount_uuid, mount_schema)

    root_schema = Schema.new_schema() |> Schema.add_directory("workspace", mount_uuid)
    create_schema(store, root_uuid, root_schema)

    put_workspace_root(workspace_dir, root_uuid)

    %{root_uuid: root_uuid, mount_uuid: mount_uuid, doc_uuid: doc_uuid}
  end

  defp start_bridge(opts) do
    name = unique_name("gb_inbound")

    {:ok, _pid} =
      Server.start_link(
        Keyword.merge(
          [branch: "main", interval_ms: 3_600_000, name: name],
          opts
        )
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)
    name
  end

  # --- "human" git helpers (raw git CLI against clone_dir) ---

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp human_clone(bare_dir, clone_dir) do
    git!(".", ["clone", bare_dir, clone_dir])
    # The bridge always pushes "main", but a fresh bare repo's symbolic
    # HEAD may still point at whatever `init.defaultBranch` resolved to
    # locally (e.g. "master") — explicitly track "main" so the human's
    # local history actually chains off the bridge's pushed content
    # instead of an unrelated empty branch.
    git!(clone_dir, ["checkout", "-B", "main", "origin/main"])
  end

  defp human_commit_and_push(clone_dir, message) do
    git!(clone_dir, ["add", "-A"])

    git!(clone_dir, [
      "-c",
      "user.name=human",
      "-c",
      "user.email=human@example.com",
      "commit",
      "-m",
      message
    ])

    git!(clone_dir, ["push", "origin", "HEAD:main"])
  end

  defp human_edit(clone_dir, rel_path, content) do
    path = Path.join(clone_dir, rel_path)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
  end

  defp doc_content(store, uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  # --- Pins ---

  test "pin 1: happy path — human edit lands as a signed CRDT commit, idempotent round-trip", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, "hello world")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)

    {:ok, r1} = Server.sync_now(name)
    assert r1.committed == true

    human_clone(bare_dir, clone_dir)
    human_edit(clone_dir, "a.txt", "hello world, edited by human")
    human_commit_and_push(clone_dir, "human edit")

    {:ok, _r2} = Server.sync_now(name)
    # reconcile push-reject if any
    {:ok, r3} = Server.sync_now(name)

    assert doc_content(store, doc_uuid) == "hello world, edited by human"

    # idempotent round-trip: one more cycle produces zero git diff.
    {:ok, r4} = Server.sync_now(name)
    assert r4.committed == false

    _ = r3
  end

  test "pin 2: anchor-replica property — CRDT edit + git edit in different regions both survive", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    original = "Paragraph A original.\n\nParagraph B original."
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, original)

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)

    {:ok, _} = Server.sync_now(name)

    # CRDT-side edit to paragraph A.
    {:ok, doc} = DocBuilder.reconstruct_doc(store, doc_uuid)
    edited_a = "Paragraph A EDITED.\n\nParagraph B original."
    doc = Commonplace.Document.Diff.apply_diff(doc, original, edited_a)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, doc_uuid, update)

    # Export cycle re-anchors sidecar to the CRDT edit (no git-side change yet).
    {:ok, _} = Server.sync_now(name)

    # Human clones the tree AFTER the CRDT edit landed, edits paragraph B.
    human_clone(bare_dir, clone_dir)
    edited_b = "Paragraph A EDITED.\n\nParagraph B EDITED."
    human_edit(clone_dir, "a.txt", edited_b)
    human_commit_and_push(clone_dir, "human edit paragraph B")

    {:ok, _} = Server.sync_now(name)
    {:ok, _} = Server.sync_now(name)

    final = doc_content(store, doc_uuid)
    assert final =~ "Paragraph A EDITED"
    assert final =~ "Paragraph B EDITED"
  end

  test "pin 3: conflict — same-region concurrent edit keeps CRDT version, writes conflict file, red event", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    original = "same region text"
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, original)

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)

    # CRDT-side edit AFTER the clone snapshot but with NO intervening
    # export cycle, so the sidecar anchor still points at `original`.
    {:ok, doc} = DocBuilder.reconstruct_doc(store, doc_uuid)
    crdt_edit = "same region text, CRDT wins here"
    doc = Commonplace.Document.Diff.apply_diff(doc, original, crdt_edit)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, doc_uuid, update)

    # Git-side edit to the SAME region, pushed without ever seeing the
    # CRDT edit.
    human_edit(clone_dir, "a.txt", "same region text, GIT wins here")
    human_commit_and_push(clone_dir, "human conflicting edit")

    PubSub.subscribe_red(mount_uuid)

    {:ok, _} = Server.sync_now(name)
    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{reason: :both_moved}}}, 2_000

    # CRDT wins: the doc keeps its own edit, git's text was never applied.
    assert doc_content(store, doc_uuid) == crdt_edit

    # Reconcile pushes over a couple more cycles; the conflict file must
    # surface in the remote eventually.
    for _ <- 1..4 do
      {:ok, _r} = Server.sync_now(name)
    end

    scratch = Path.join(System.tmp_dir!(), "cp_gb_in_scratch_#{:rand.uniform(1_000_000_000)}")
    on_exit(fn -> File.rm_rf!(scratch) end)
    git!(".", ["clone", bare_dir, scratch])
    git!(scratch, ["checkout", "-B", "main", "origin/main"])

    conflict_files = scratch |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "a.txt.conflict-"))
    assert conflict_files != []
  end

  test "pin 4: push-race — human pushes between fetch and push, worktree resets, next cycle converges", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, "base content")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)
    human_edit(clone_dir, "a.txt", "base content, human wins the race")
    human_commit_and_push(clone_dir, "race edit")

    # First reconciliation: ingest sees the human edit as clean-path
    # (ours == base), mints it, but the resulting local commit's parent
    # predates the human's push -> push is rejected -> worktree resets
    # hard to remote head per the disposable-projections rule.
    {:ok, _} = Server.sync_now(name)
    # Second cycle regenerates from the (now-updated) store and converges.
    {:ok, r2} = Server.sync_now(name)

    assert doc_content(store, doc_uuid) == "base content, human wins the race"

    # No force, no duplicate content: bare repo's a.txt matches exactly.
    scratch = Path.join(System.tmp_dir!(), "cp_gb_in_scratch2_#{:rand.uniform(1_000_000_000)}")
    on_exit(fn -> File.rm_rf!(scratch) end)
    git!(".", ["clone", bare_dir, scratch])
    git!(scratch, ["checkout", "-B", "main", "origin/main"])
    assert File.read!(Path.join(scratch, "a.txt")) == "base content, human wins the race"

    _ = r2
  end

  test "pin 5: force-push — rewritten remote history halts inbound + red event; export still runs", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid} = seed_single_doc(store, workspace_dir, "content")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)
    git!(clone_dir, ["checkout", "--orphan", "rewritten"])
    git!(clone_dir, ["rm", "-rf", "."])
    File.write!(Path.join(clone_dir, "rewritten.txt"), "rewritten history")

    git!(clone_dir, ["add", "-A"])

    git!(clone_dir, [
      "-c",
      "user.name=human",
      "-c",
      "user.email=human@example.com",
      "commit",
      "-m",
      "rewrite history"
    ])

    git!(clone_dir, ["push", "--force", "origin", "rewritten:main"])

    PubSub.subscribe_red(mount_uuid)

    {:ok, result} = Server.sync_now(name)
    assert_receive {"red:" <> _, {:git_bridge, :force_push_detected, _meta}}, 2_000
    # Export continues undisturbed — the cycle doesn't error out.
    assert match?(%{}, result)
  end

  test "pin 6: structured-class rejection — xml doc git edit rejected to conflict path, doc unchanged", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_xml_doc(store, workspace_dir)

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    {:ok, before_doc} = DocBuilder.reconstruct_doc(store, doc_uuid)
    before_xml = CanonicalXml.encode(ContentType.get_content(before_doc))

    human_clone(bare_dir, clone_dir)
    human_edit(clone_dir, "_outline", "<totally>hand-edited</totally>\n")
    human_commit_and_push(clone_dir, "edit xml file")

    PubSub.subscribe_red(mount_uuid)
    {:ok, _} = Server.sync_now(name)
    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{reason: :structured_class}}}, 2_000

    {:ok, after_doc} = DocBuilder.reconstruct_doc(store, doc_uuid)
    after_xml = CanonicalXml.encode(ContentType.get_content(after_doc))
    assert after_xml == before_xml
  end

  test "pin 7: add/delete rejection — git-side new file and deletion both rejected to conflict path", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, "keep me")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)
    File.write!(Path.join(clone_dir, "new_file.txt"), "brand new")
    File.rm!(Path.join(clone_dir, "a.txt"))
    human_commit_and_push(clone_dir, "add + delete")

    PubSub.subscribe_red(mount_uuid)
    {:ok, _} = Server.sync_now(name)

    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{rel_path: "new_file.txt", reason: :added}}}, 2_000
    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{rel_path: "a.txt", reason: :deleted}}}, 2_000

    # Doc content untouched by the deletion.
    assert doc_content(store, doc_uuid) == "keep me"

    # Next export regenerates the deleted file.
    {:ok, _} = Server.sync_now(name)
    {:ok, _} = Server.sync_now(name)
    assert File.exists?(Path.join(repo_dir, "a.txt"))
  end

  test "pin 8: sidecar tamper — editing .commonplace/* on git side is ignored entirely", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, "unchanged content")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)
    tamper_path = Path.join(clone_dir, ".commonplace/a.txt.json")
    File.write!(tamper_path, Jason.encode!(%{"uuid" => "not-a-real-uuid", "type" => "text", "anchor" => nil}))
    human_commit_and_push(clone_dir, "tamper with sidecar")

    {:ok, _} = Server.sync_now(name)

    assert doc_content(store, doc_uuid) == "unchanged content"

    # Sidecar gets regenerated to the correct, bridge-owned values.
    regenerated = Jason.decode!(File.read!(Path.join(repo_dir, ".commonplace/a.txt.json")))
    assert regenerated["uuid"] == doc_uuid
  end

  test "pin 9: echo — a cycle right after our own push ingests nothing", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir
  } do
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, "steady state")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    {:ok, before} = DocBuilder.reconstruct_doc(store, doc_uuid)
    before_content = ContentType.get_content(before)

    {:ok, r2} = Server.sync_now(name)
    assert r2.committed == false

    assert doc_content(store, doc_uuid) == before_content
  end

  test "pin 10: size guard — oversized edit routes to conflict path without running Myers", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    prev = Application.get_env(:commonplace, :git_bridge_max_inbound_bytes)
    Application.put_env(:commonplace, :git_bridge_max_inbound_bytes, 16)

    on_exit(fn ->
      if prev do
        Application.put_env(:commonplace, :git_bridge_max_inbound_bytes, prev)
      else
        Application.delete_env(:commonplace, :git_bridge_max_inbound_bytes)
      end
    end)

    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, "short")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)
    human_edit(clone_dir, "a.txt", "this content is way over the tiny size guard limit")
    human_commit_and_push(clone_dir, "oversized edit")

    PubSub.subscribe_red(mount_uuid)
    {:ok, _} = Server.sync_now(name)
    assert_receive {"red:" <> _, {:git_bridge, :inbound_size_capped, _meta}}, 2_000

    assert doc_content(store, doc_uuid) == "short"
  end
end
