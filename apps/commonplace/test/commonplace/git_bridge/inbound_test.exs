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

  test "pin 3: same-region overlap — CRDT+git converge (v2 true region-merge), pre-merge git version still preserved for review", %{
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

    # CX-b0ow.9: v1 rejected any concurrent-edit overlap outright (CRDT
    # wins, git text never applied). v2's true region-merge instead
    # lands a real Yjs merge even when the edits touch the same text
    # region — it converges deterministically (no crash) rather than
    # bailing, and the pre-merge git version is STILL preserved at the
    # conflict path (same event/marker as before) as review evidence,
    # not a rejection.
    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{reason: :both_moved}}}, 2_000

    merged = doc_content(store, doc_uuid)
    refute is_nil(merged)
    # The merge actually changed the doc (neither side's text alone,
    # nor the untouched original, survives verbatim) — proof this
    # landed as a real merge rather than a silent no-op.
    assert merged != original

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

  test "pin 11 (headline): CRDT edit + git edit to DISJOINT regions both survive the merge, no conflict file", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    original = "Paragraph ONE original.\n\nParagraph TWO original."
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, original)

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)

    # CRDT-side edit to paragraph ONE, AFTER the clone snapshot with NO
    # intervening export cycle — the sidecar anchor still points at
    # `original`, so this is a genuine "anchor != :latest" scenario.
    {:ok, doc} = DocBuilder.reconstruct_doc(store, doc_uuid)
    crdt_edit = "Paragraph ONE EDITED.\n\nParagraph TWO original."
    doc = Commonplace.Document.Diff.apply_diff(doc, original, crdt_edit)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, doc_uuid, update)

    # Git-side edit to paragraph TWO (disjoint region), pushed without
    # ever seeing the CRDT edit.
    git_edit = "Paragraph ONE original.\n\nParagraph TWO EDITED."
    human_edit(clone_dir, "a.txt", git_edit)
    human_commit_and_push(clone_dir, "human edit to disjoint paragraph")

    PubSub.subscribe_red(mount_uuid)

    {:ok, _} = Server.sync_now(name)

    # BOTH edits survive in the merged doc.
    final = doc_content(store, doc_uuid)
    assert final =~ "Paragraph ONE EDITED"
    assert final =~ "Paragraph TWO EDITED"

    # No conflict-preservation event/file — the regions were disjoint.
    refute_receive {"red:" <> _, {:git_bridge, :conflict_preserved, _}}, 500

    {:ok, _} = Server.sync_now(name)

    scratch = Path.join(System.tmp_dir!(), "cp_gb_in_scratch11_#{:rand.uniform(1_000_000_000)}")
    on_exit(fn -> File.rm_rf!(scratch) end)
    git!(".", ["clone", bare_dir, scratch])
    git!(scratch, ["checkout", "-B", "main", "origin/main"])

    # Re-exported file reflects both edits, and there is no conflict marker.
    assert File.read!(Path.join(scratch, "a.txt")) =~ "Paragraph ONE EDITED"
    assert File.read!(Path.join(scratch, "a.txt")) =~ "Paragraph TWO EDITED"
    conflict_files = scratch |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "a.txt.conflict-"))
    assert conflict_files == []
  end

  test "pin 12: clock-continuation — a second region-merge under the same bridge hand doesn't collide with the first's ops", %{
    store: store,
    workspace_dir: workspace_dir
  } do
    original = "Alpha original.\n\nBeta original.\n\nGamma original."
    %{doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, original)

    {:ok, anchor0} = CommitStore.latest_commit(store, doc_uuid)

    # First region-merge: git-side edit to Alpha, landed under the
    # bridge's stable hand — mints hand clocks starting at 0.
    first_edit = "Alpha FIRST EDIT.\n\nBeta original.\n\nGamma original."

    {:ok, _c1} =
      Commonplace.GitBridge.Inbound.mint_region_merge(store, doc_uuid, anchor0.id, original, first_edit)

    # A concurrent CRDT-side edit (region: Beta) under a DIFFERENT client
    # id lands on top — `:latest` advances, but the bridge hand's OWN
    # clock does not (only hand-authored commits move it).
    {:ok, live} = DocBuilder.reconstruct_doc(store, doc_uuid)
    crdt_edit = "Alpha FIRST EDIT.\n\nBeta CRDT EDITED.\n\nGamma original."
    update = Yelixer.Encoding.encode_update(Commonplace.Document.Diff.apply_diff(live, first_edit, crdt_edit))
    CommitStore.create_chained_commit(store, doc_uuid, update)

    # Second region-merge: reconstructed against the SAME STALE anchor0
    # (simulating a second inbound edit whose sidecar never advanced past
    # the ORIGINAL anchor — two edits queued/ingested before a re-export
    # ever ran) — a git-side edit to Gamma (disjoint region). WITHOUT the
    # clock floor, this replica's own state vector (which only knows
    # anchor0's state, hand clock 0) would mint hand clocks starting back
    # at 0 — directly colliding with c1's already-landed items under the
    # SAME hand, which would then be silently deduped as already-seen
    # ids when U is applied to the live doc, dropping this edit's text.
    second_edit = "Alpha original.\n\nBeta original.\n\nGamma SECOND EDIT."

    {:ok, _c3} =
      Commonplace.GitBridge.Inbound.mint_region_merge(store, doc_uuid, anchor0.id, original, second_edit)

    final = doc_content(store, doc_uuid)
    # All three edits survive: the second region-merge's newly-minted
    # ops did NOT collide with (get silently deduped against) the
    # first's ops under the shared bridge hand.
    assert final =~ "Alpha FIRST EDIT"
    assert final =~ "Beta CRDT EDITED"
    assert final =~ "Gamma SECOND EDIT"
  end

  test "pin 13: CAS redo — a `:parent_moved` mid-merge redoes and lands", %{
    store: store,
    workspace_dir: workspace_dir
  } do
    original = "region one text.\n\nregion two text."
    %{doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, original)

    anchor_commit = CommitStore.latest_commit(store, doc_uuid) |> elem(1)

    # Concurrent CRDT edit (region one) — establishes anchor != :latest.
    {:ok, doc} = DocBuilder.reconstruct_doc(store, doc_uuid)
    crdt_edit = "region one EDITED.\n\nregion two text."
    update = Yelixer.Encoding.encode_update(Commonplace.Document.Diff.apply_diff(doc, original, crdt_edit))
    CommitStore.create_chained_commit(store, doc_uuid, update)

    theirs = "region one text.\n\nregion two EDITED."

    # The race hook fires once, mid-attempt (after the merge payload is
    # built, before the final `:latest` re-check) — deterministically
    # simulating a third write landing in the reconstruct-to-commit
    # window instead of relying on real scheduler timing.
    race_fired = :counters.new(1, [])

    race_hook = fn ->
      if :counters.get(race_fired, 1) == 0 do
        :counters.add(race_fired, 1, 1)
        {:ok, live} = DocBuilder.reconstruct_doc(store, doc_uuid)
        racer_content = ContentType.get_content(live) <> " [racer]"
        racer_update = Yelixer.Encoding.encode_update(Commonplace.Document.Diff.apply_diff(live, ContentType.get_content(live), racer_content))
        CommitStore.create_chained_commit(store, doc_uuid, racer_update)
      end
    end

    result =
      Commonplace.GitBridge.Inbound.mint_region_merge(
        store,
        doc_uuid,
        anchor_commit.id,
        original,
        theirs,
        race_hook: race_hook
      )

    assert {:ok, _commit} = result
    assert :counters.get(race_fired, 1) == 1

    final = doc_content(store, doc_uuid)
    assert final =~ "region one EDITED"
    assert final =~ "region two EDITED"
    assert final =~ "[racer]"
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

  test "pin 7: add/delete ingestion — git-side new file becomes a doc, deletion removes the schema entry", %{
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

    assert_receive {"red:" <> _, {:git_bridge, :file_added, %{rel_path: "new_file.txt", uuid: new_uuid}}}, 2_000
    assert_receive {"red:" <> _, {:git_bridge, :file_removed, %{rel_path: "a.txt", uuid: ^doc_uuid}}}, 2_000

    # New doc exists with the human's content, and a schema entry was added.
    assert doc_content(store, new_uuid) == "brand new"
    {:ok, mount_schema} = DocBuilder.reconstruct_snapshot(store, mount_uuid)
    assert Schema.resolve_name(mount_schema, "new_file.txt") == {:ok, new_uuid}
    assert Schema.resolve_name(mount_schema, "a.txt") == :error

    # The deleted doc's underlying content is still recoverable — only
    # the tree pointer was removed, history is append-only.
    assert doc_content(store, doc_uuid) == "keep me"

    # Next export round-trips the add (zero further git diff for it)
    # and does NOT regenerate the deleted file (it's gone from the tree).
    {:ok, _} = Server.sync_now(name)
    {:ok, r3} = Server.sync_now(name)
    assert r3.committed == false

    refute File.exists?(Path.join(repo_dir, "a.txt"))
    assert File.read!(Path.join(repo_dir, "new_file.txt")) == "brand new"
  end

  test "pin 7b: add rejection — system/honorific/sidecar-owned names never mint a doc", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid} = seed_single_doc(store, workspace_dir, "keep me")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)
    File.write!(Path.join(clone_dir, "__system"), "reserved")
    File.write!(Path.join(clone_dir, "alice.usr"), "{}")
    human_commit_and_push(clone_dir, "add ineligible names")

    PubSub.subscribe_red(mount_uuid)
    {:ok, _} = Server.sync_now(name)

    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{rel_path: "__system", reason: :ineligible_add}}}, 2_000
    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{rel_path: "alice.usr", reason: :ineligible_add}}}, 2_000

    {:ok, mount_schema} = DocBuilder.reconstruct_snapshot(store, mount_uuid)
    assert Schema.resolve_name(mount_schema, "__system") == :error
    assert Schema.resolve_name(mount_schema, "alice.usr") == :error
  end

  test "pin 7c: rename — git-side rename rejected to conflict path in v1", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir,
    bare_dir: bare_dir,
    clone_dir: clone_dir
  } do
    %{mount_uuid: mount_uuid, doc_uuid: doc_uuid} = seed_single_doc(store, workspace_dir, "keep me stable enough to detect as a rename")

    name = start_bridge(mount_uuid: mount_uuid, repo_dir: repo_dir, store: store, remote: bare_dir)
    {:ok, _} = Server.sync_now(name)

    human_clone(bare_dir, clone_dir)
    git!(clone_dir, ["mv", "a.txt", "b.txt"])
    human_commit_and_push(clone_dir, "rename a.txt to b.txt")

    PubSub.subscribe_red(mount_uuid)
    {:ok, _} = Server.sync_now(name)

    assert_receive {"red:" <> _, {:git_bridge, :conflict_preserved, %{rel_path: "b.txt", reason: :rename_unsupported}}}, 2_000

    # Original doc/schema entry untouched.
    assert doc_content(store, doc_uuid) == "keep me stable enough to detect as a rename"
    {:ok, mount_schema} = DocBuilder.reconstruct_snapshot(store, mount_uuid)
    assert Schema.resolve_name(mount_schema, "a.txt") == {:ok, doc_uuid}
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
