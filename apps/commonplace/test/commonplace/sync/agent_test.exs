defmodule Commonplace.Sync.AgentTest do
  @moduledoc """
  Tests for the bidirectional sync agent.

  The sync agent watches both disk and CRDT for changes:
  - Outbound: disk changes → detect → lock → read → diff → commit
  - Inbound: CRDT update (PubSub) → ancestry check → lock → atomic write
  """
  use ExUnit.Case

  alias Commonplace.Sync.{Agent, InodeTracker}
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_agent_store_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_agent_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(sync_dir)

    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(sync_dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{
      store: store_name,
      sync_dir: sync_dir,
      root: root_uuid
    }
  end

  defp loader(store) do
    fn uuid ->
      case CommitStore.latest_commit(store, uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema()
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema()
      end
    end
  end

  defp read_content(uuid, store) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    ContentType.get_content(doc)
  end

  describe "outbound sync (disk → CRDT)" do
    test "new file on disk is synced to CRDT", %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "new.txt"), "new content")

      {:ok, pid} =
        Agent.start_link(
          root_uuid: root,
          sync_dir: dir,
          store: store
        )

      Agent.sync_once(pid)

      load = loader(store)
      {:ok, uuid} = Walk.resolve_path(root, "new.txt", load)
      assert read_content(uuid, store) == "new content"
    end

    test "modified file on disk is synced to CRDT", %{store: store, sync_dir: dir, root: root} do
      # Setup: create file and sync it
      File.write!(Path.join(dir, "file.txt"), "original")

      {:ok, pid} =
        Agent.start_link(
          root_uuid: root,
          sync_dir: dir,
          store: store
        )

      Agent.sync_once(pid)

      load = loader(store)
      {:ok, uuid} = Walk.resolve_path(root, "file.txt", load)
      assert read_content(uuid, store) == "original"

      # Modify and sync again
      File.write!(Path.join(dir, "file.txt"), "updated")
      Agent.sync_once(pid)

      assert read_content(uuid, store) == "updated"
    end

    test "deleted file on disk is removed from schema", %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "temp.txt"), "temporary")

      {:ok, pid} =
        Agent.start_link(
          root_uuid: root,
          sync_dir: dir,
          store: store
        )

      Agent.sync_once(pid)

      load = loader(store)
      {:ok, _} = Walk.resolve_path(root, "temp.txt", load)

      File.rm!(Path.join(dir, "temp.txt"))
      Agent.sync_once(pid)

      assert {:error, {:not_found, "temp.txt"}} = Walk.resolve_path(root, "temp.txt", load)
    end
  end

  describe "inbound sync (CRDT → disk)" do
    test "CRDT document change is written to disk", %{store: store, sync_dir: dir, root: root} do
      # Create a document in CRDT directly
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "from_crdt.txt")
      doc = ContentType.insert_text(doc, 0, "from CRDT\n")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      # Add to schema
      root_doc = loader(store).(root)
      root_doc = Schema.add_file(root_doc, "from_crdt.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      {:ok, pid} =
        Agent.start_link(
          root_uuid: root,
          sync_dir: dir,
          store: store
        )

      # Export phase of sync should write to disk
      Agent.sync_once(pid)

      assert File.read!(Path.join(dir, "from_crdt.txt")) == "from CRDT\n"
    end
  end

  describe "bidirectional" do
    test "edits on disk and CRDT both appear after sync", %{
      store: store,
      sync_dir: dir,
      root: root
    } do
      # Start with two files
      File.write!(Path.join(dir, "disk_file.txt"), "from disk")

      {:ok, pid} =
        Agent.start_link(
          root_uuid: root,
          sync_dir: dir,
          store: store
        )

      Agent.sync_once(pid)

      # Now add a CRDT-side document
      crdt_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "crdt_file.txt")
      doc = ContentType.insert_text(doc, 0, "from crdt")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, crdt_uuid, update, nil)

      root_doc = loader(store).(root)
      root_doc = Schema.add_file(root_doc, "crdt_file.txt", crdt_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      # CX-86t2: MUST use create_chained_commit (not create_commit with
      # parent_id=nil) so this write chains onto the current :latest
      # rather than creating an unchained branch. Unchained writes race
      # with the background reflog checkpoint (Task.start from the prior
      # sync_once): the checkpoint's load+mutate+create_chained_commit
      # sequence is TOCTOU-unsafe, and if the checkpoint chains a commit
      # whose update bytes were encoded from a pre-test state, the
      # test's crdt_file.txt entry gets silently dropped from :latest.
      # See CX-86t2 for the broader checkpoint-race fix.
      CommitStore.create_chained_commit(store, root, update)

      # Also edit disk_file.txt on disk
      File.write!(Path.join(dir, "disk_file.txt"), "from disk (edited)")

      Agent.sync_once(pid)

      # Both changes should be reflected
      load = loader(store)
      {:ok, disk_uuid} = Walk.resolve_path(root, "disk_file.txt", load)
      assert read_content(disk_uuid, store) == "from disk (edited)"
      assert File.read!(Path.join(dir, "crdt_file.txt")) == "from crdt"
    end

    test "sync is idempotent", %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "stable.txt"), "stable")

      {:ok, pid} =
        Agent.start_link(
          root_uuid: root,
          sync_dir: dir,
          store: store
        )

      Agent.sync_once(pid)
      Agent.sync_once(pid)
      Agent.sync_once(pid)

      load = loader(store)
      {:ok, uuid} = Walk.resolve_path(root, "stable.txt", load)
      assert read_content(uuid, store) == "stable"
      assert File.read!(Path.join(dir, "stable.txt")) == "stable"
    end
  end

  # CX-60wl: the sync cycle's end-of-cycle known_hashes must record only
  # content the agent OBSERVED-AND-RECONCILED this cycle (the pre-outbound
  # disk snapshot overlaid with the exact bytes inbound wrote) — never a blind
  # post-outbound disk rescan, which would absorb a mid-cycle write that
  # outbound never committed → silent data loss.
  describe "CX-60wl: snapshot-consistent known_hashes" do
    test "an inbound-written file is a strict NO-OP on the next cycle (rel-path key + byte-match align)",
         %{store: store, sync_dir: dir, root: root} do
      # Seed a top-level doc AND a NESTED doc (exercises the prefix/name
      # rel-path key scheme) purely in the CRDT — inbound must export both.
      top = make_doc(store, "top.txt", "top content")
      nested = make_doc(store, "b.txt", "nested content")

      sub = UUID.uuid4()
      sub_schema = Schema.new_schema() |> Schema.add_file("b.txt", nested)
      CommitStore.create_commit(store, sub, Yelixer.Encoding.encode_update(sub_schema), nil)

      root_doc =
        loader(store).(root)
        |> Schema.add_file("top.txt", top)
        |> Schema.add_directory("sub", sub)

      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, pid} = Agent.start_link(root_uuid: root, sync_dir: dir, store: store)

      # Cycle 1: inbound exports both to disk and records them as reconciled.
      Agent.sync_once(pid)
      assert File.read!(Path.join(dir, "top.txt")) == "top content"
      assert File.read!(Path.join([dir, "sub", "b.txt"])) == "nested content"

      top_before = latest_id(store, top)
      nested_before = latest_id(store, nested)

      # Cycle 2: no disk change. If the inbound-written hash sits under a
      # rel-path key that doesn't match scan_disk_state's key — or the stored
      # bytes don't match the on-disk bytes — outbound sees the file as
      # "changed" and spuriously re-commits (a loop through the KEY door).
      # Correct alignment ⇒ zero new commits.
      Agent.sync_once(pid)

      assert latest_id(store, top) == top_before,
             "top-level inbound file re-committed on a no-op cycle (key/byte misalign)"

      assert latest_id(store, nested) == nested_before,
             "nested inbound file re-committed on a no-op cycle (rel-path key misalign)"
    end

    test "every edit reaches the CRDT — no modification is absorbed unbuilt",
         %{store: store, sync_dir: dir, root: root} do
      {:ok, pid} = Agent.start_link(root_uuid: root, sync_dir: dir, store: store)

      File.write!(Path.join(dir, "doc.txt"), "v0")
      Agent.sync_once(pid)
      {:ok, uuid} = Walk.resolve_path(root, "doc.txt", loader(store))

      # Each modification, cycle after cycle, must land in the CRDT — none may
      # be silently swallowed by the known_hashes update.
      for i <- 1..25 do
        File.write!(Path.join(dir, "doc.txt"), "v#{i}")
        Agent.sync_once(pid)
        assert read_content(uuid, store) == "v#{i}", "edit v#{i} was lost"
      end
    end

    test "shadow-tracking closes the inbound-guard's read→write TOCTOU residual",
         %{store: store, sync_dir: dir, root: root} do
      # The inbound guard shrinks the clobber window to a μs read→write TOCTOU
      # but doesn't fully close it. Shadow-tracking is the REACTIVE backstop:
      # an out-of-band edit that lands after an inbound write (the residual's
      # worst case) is detected via the shadow fingerprint and recommitted, so
      # it is NOT lost.
      f = make_doc(store, "f.txt", "v1")

      root_doc = loader(store).(root) |> Schema.add_file("f.txt", f)
      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, pid} =
        Agent.start_link(root_uuid: root, sync_dir: dir, store: store, shadow_tracking: true)

      # Cycle 1: inbound writes v1 to disk and hardlinks its shadow.
      Agent.sync_once(pid)
      assert File.read!(Path.join(dir, "f.txt")) == "v1"

      # An out-of-band edit lands (the residual's clobbered write). Disk now
      # diverges from the shadow.
      File.write!(Path.join(dir, "f.txt"), "v2-edit")

      # Cycle 2: Phase-0 check_shadows sees disk != shadow → recovers the edit
      # into the CRDT rather than losing it.
      Agent.sync_once(pid)
      assert read_content(f, store) == "v2-edit", "shadow-tracking failed to recover the edit"
    end

    test "CX-k34x: a reconciled shadow's registry entry is evicted, not leaked",
         %{store: store, sync_dir: dir, root: root} do
      # Regression test for unbounded InodeTracker.Registry growth:
      # Registry.track/5 runs on every inbound write, but nothing called
      # Registry.remove_shadow/2 after a shadow was reconciled — so the
      # in-memory map grew one entry per write for the life of the BEAM.
      #
      # To exercise the actual shadowed→reconciled→evicted path (not just
      # the ordinary outbound hash-mismatch path, which recovers disk
      # edits independently of shadow-tracking), this drives TWO real
      # inbound writes to the same path so the second one shadows the
      # first's inode, then simulates a stale-fd write directly onto the
      # shadow hardlink — exactly what check_shadows exists to detect.
      f = make_doc(store, "f.txt", "v1")

      root_doc = loader(store).(root) |> Schema.add_file("f.txt", f)
      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, pid} =
        Agent.start_link(root_uuid: root, sync_dir: dir, store: store, shadow_tracking: true)

      # Cycle 1: inbound writes v1 — Registry.track/5 records the new inode
      # (not yet shadowed, nothing to reconcile).
      Agent.sync_once(pid)
      assert File.read!(Path.join(dir, "f.txt")) == "v1"

      inode_registry = :sys.get_state(pid).inode_registry

      # A second CRDT-side update lands (simulating a remote write), so the
      # next inbound export performs a SECOND atomic write to the same
      # path — this is what shadows the v1 inode (hardlinks it, marks the
      # registry entry shadowed: true) before replacing it with v2.
      f_doc =
        Yelixer.Doc.new()
        |> Commonplace.Document.ContentType.create(:text, "f.txt")
        |> Commonplace.Document.ContentType.insert_text(0, "v2")

      {:ok, latest} = CommitStore.latest_commit(store, f)
      CommitStore.create_commit(store, f, Yelixer.Encoding.encode_update(f_doc), latest.id)

      Agent.sync_once(pid)
      assert File.read!(Path.join(dir, "f.txt")) == "v2"

      shadows_after_cycle2 = InodeTracker.Registry.list_shadows(inode_registry)

      assert [shadow] = shadows_after_cycle2,
             "expected exactly one shadowed (v1) entry after the second write"

      # The v1 entry's commit_id uniquely identifies it. We check for
      # eviction of THIS commit_id below rather than the (dev, inode) map
      # key, because the reconciliation commit created in cycle 3 causes
      # a THIRD atomic write in the same cycle (Phase 2 inbound export
      # sees the CRDT moved again) whose temp+rename can be assigned a
      # freed inode number by the filesystem — coincidentally reusing the
      # very key we just evicted. That reuse is an unrelated filesystem
      # quirk, not a leak; asserting on commit_id sidesteps it.
      v1_commit_id = shadow.commit_id

      # Simulate a stale fd: write directly onto the shadow hardlink,
      # which still shares the v1 inode.
      File.write!(shadow.shadow_path, "stale content from a lingering fd")

      # Cycle 3: Phase-0 check_shadows detects the stale write, reconciles
      # it into the CRDT, deletes the shadow file, and (post-fix) must
      # evict the now-reconciled v1 registry entry too.
      Agent.sync_once(pid)

      refute File.exists?(shadow.shadow_path), "shadow file should have been cleaned up"

      registry_entries = :sys.get_state(inode_registry) |> Map.values()

      refute Enum.any?(registry_entries, &(&1.commit_id == v1_commit_id)),
             "reconciled shadow's registry entry was not evicted (unbounded growth regression)"
    end

    test "CX-wrg0: steady overwrites with no stale writers don't leak registry entries or shadow files",
         %{store: store, sync_dir: dir, root: root} do
      # Second growth vector: CX-k34x only evicts a shadow whose fingerprint
      # DIVERGED (a stale fd actually wrote to it). A shadow that's created
      # every overwrite but NEVER diverges (the common case — nothing has a
      # stale fd open) never reached that branch, so both the registry entry
      # and the shadow hardlink leaked once per overwrite, forever.
      f = make_doc(store, "f.txt", "v0")

      root_doc = loader(store).(root) |> Schema.add_file("f.txt", f)
      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, pid} =
        Agent.start_link(root_uuid: root, sync_dir: dir, store: store, shadow_tracking: true)

      inode_registry = :sys.get_state(pid).inode_registry
      shadow_dir = Path.join(dir, ".commonplace-shadow")

      # Cycle 1: writes v0, nothing tracked yet to shadow.
      Agent.sync_once(pid)
      assert File.read!(Path.join(dir, "f.txt")) == "v0"

      # N further generations, each landing purely via a CRDT-side commit
      # (so every cycle performs a real inbound atomic write — the only
      # path that shadows/tracks — with no out-of-band disk edits at all).
      n = 8

      for i <- 1..n do
        crdt_overwrite(store, f, "v#{i}")
        Agent.sync_once(pid)
        assert File.read!(Path.join(dir, "f.txt")) == "v#{i}"
      end

      registry_entries_for_path =
        :sys.get_state(inode_registry)
        |> Map.values()
        |> Enum.filter(&(&1.path == Path.join(dir, "f.txt")))

      shadowed_entries = Enum.filter(registry_entries_for_path, & &1.shadowed)

      shadow_files =
        case File.ls(shadow_dir) do
          {:ok, files} -> files
          {:error, :enoent} -> []
        end

      assert length(shadowed_entries) <= 1,
             "expected at most one shadowed (previous-generation) registry entry after #{n + 1} overwrites, got #{length(shadowed_entries)}"

      assert length(shadow_files) <= 1,
             "expected at most one shadow hardlink on disk after #{n + 1} overwrites, got #{length(shadow_files)}: #{inspect(shadow_files)}"

      # Bounded, not O(N): total tracked entries for this path never grows
      # past "current generation" + "one pending-reconciliation previous
      # generation" regardless of how many overwrites ran.
      assert length(registry_entries_for_path) <= 2,
             "registry entries for f.txt grew unboundedly: #{length(registry_entries_for_path)} entries after #{n + 1} overwrites"
    end

    test "CX-wrg0: a stale write to the previous generation is still recovered, not silently evicted",
         %{store: store, sync_dir: dir, root: root} do
      # CX-wrg0's fix makes clean (never-diverged) shadows evictable at
      # supersession time. This guards against the naive version of that
      # fix — evicting unconditionally instead of rechecking the
      # fingerprint first — which would silently drop a genuine stale-fd
      # write instead of routing it through the existing recovery path.
      # It also confirms the fix keeps behaving correctly across a
      # recover-then-overwrite-again sequence (no crash, no leak).
      f = make_doc(store, "f.txt", "v1")

      root_doc = loader(store).(root) |> Schema.add_file("f.txt", f)
      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, pid} =
        Agent.start_link(root_uuid: root, sync_dir: dir, store: store, shadow_tracking: true)

      inode_registry = :sys.get_state(pid).inode_registry

      # Cycle 1: writes v1 (untracked path, nothing to shadow yet).
      Agent.sync_once(pid)
      assert File.read!(Path.join(dir, "f.txt")) == "v1"

      # Cycle 2: a CRDT-side v2 update forces a second inbound write, which
      # shadows the v1 inode (creates the previous-generation shadow entry).
      crdt_overwrite(store, f, "v2")
      Agent.sync_once(pid)
      assert File.read!(Path.join(dir, "f.txt")) == "v2"

      [shadow] = InodeTracker.Registry.list_shadows(inode_registry)

      # Simulate a stale fd still holding the v1 inode: write directly onto
      # the shadow hardlink. Nothing else changes on disk or in the CRDT —
      # this is exactly the "never diverged... until now" case a naive
      # supersession-cleanup (evict unconditionally, no fingerprint recheck)
      # would silently drop.
      File.write!(shadow.shadow_path, "stale v1 content from a lingering fd")

      # Cycle 3: Phase-0 check_shadows (still evict_if_clean: false, i.e.
      # the CX-wrg0 change did not touch this path) finds the divergence
      # and routes it through the existing recovery path, same as CX-k34x.
      Agent.sync_once(pid)

      assert read_content(f, store) == "stale v1 content from a lingering fd",
             "stale write to the previous generation was lost instead of recovered"

      refute File.exists?(shadow.shadow_path),
             "reconciled v1 shadow file should have been cleaned up"

      registry_entries = :sys.get_state(inode_registry) |> Map.values()

      refute Enum.any?(registry_entries, &(&1.shadow_path == shadow.shadow_path)),
             "reconciled v1 registry entry was not evicted"

      # Cycle 4: confirm the fix keeps working normally AFTER a recovery —
      # one more real generation lands, its write goes through
      # reconcile_superseded_shadow (which finds nothing left to reconcile,
      # since v1 was already evicted above) with no crash and no leak.
      crdt_overwrite(store, f, "v-final")
      Agent.sync_once(pid)

      assert File.read!(Path.join(dir, "f.txt")) == "v-final"

      final_entries_for_path =
        :sys.get_state(inode_registry)
        |> Map.values()
        |> Enum.filter(&(&1.path == Path.join(dir, "f.txt")))

      assert length(final_entries_for_path) <= 2,
             "registry entries for f.txt grew unboundedly after a post-recovery overwrite"
    end
  end

  describe "crash containment (CX-42no)" do
    test "permission-denied file doesn't crash sync_once; other files still sync",
         %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "ok.txt"), "fine")
      bad_path = Path.join(dir, "bad.txt")
      File.write!(bad_path, "secret")
      File.chmod!(bad_path, 0o000)
      on_exit(fn -> File.chmod(bad_path, 0o644) end)

      if root_bypasses_perms?(bad_path) do
        :ok
      else
        {:ok, pid} = Agent.start_link(root_uuid: root, sync_dir: dir, store: store)

        # Must not raise/crash even though bad.txt can't be read.
        assert :ok = Agent.sync_once(pid)

        load = loader(store)
        assert {:ok, uuid} = Walk.resolve_path(root, "ok.txt", load)
        assert read_content(uuid, store) == "fine"
        assert {:error, _} = Walk.resolve_path(root, "bad.txt", load)
      end
    end

    test "symlinked directory cycle in sync_dir does not hang or crash sync_once",
         %{store: store, sync_dir: dir, root: root} do
      loop_dir = Path.join(dir, "loop")
      File.mkdir_p!(loop_dir)
      File.write!(Path.join(loop_dir, "inside.txt"), "hi")
      # dir/loop/self -> dir/loop : a directory symlink cycle
      File.ln_s!(loop_dir, Path.join(loop_dir, "self"))

      {:ok, pid} = Agent.start_link(root_uuid: root, sync_dir: dir, store: store)

      task = Task.async(fn -> Agent.sync_once(pid) end)
      result = Task.yield(task, 10_000) || Task.shutdown(task)

      assert match?({:ok, :ok}, result),
             "sync_once hung or crashed on a symlink cycle: #{inspect(result)}"

      load = loader(store)
      assert {:ok, uuid} = Walk.resolve_path(root, "loop/inside.txt", load)
      assert read_content(uuid, store) == "hi"
    end
  end

  defp root_bypasses_perms?(path) do
    case File.read(path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp make_doc(store, name, content) do
    uuid = UUID.uuid4()

    doc =
      Yelixer.Doc.new()
      |> ContentType.create(:text, name)
      |> ContentType.insert_text(0, content)

    CommitStore.create_commit(store, uuid, Yelixer.Encoding.encode_update(doc), nil)
    uuid
  end

  defp latest_id(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    commit.id
  end

  # Push a new CRDT-side generation for a text doc, chained onto its
  # current latest commit — simulates a remote/CRDT-side write landing
  # (as opposed to a disk-side edit), which is what forces the agent's
  # NEXT inbound export to perform a real atomic_write_with_shadow call.
  defp crdt_overwrite(store, uuid, content) do
    {:ok, latest} = CommitStore.latest_commit(store, uuid)

    doc =
      Yelixer.Doc.new()
      |> ContentType.create(:text, "f.txt")
      |> ContentType.insert_text(0, content)

    CommitStore.create_commit(store, uuid, Yelixer.Encoding.encode_update(doc), latest.id)
  end
end
