defmodule Commonplace.Document.ServerSyncTest do
  @moduledoc """
  Tests for Document.Server handling of {:remote_commit, ...} messages
  from the distributed sync channel.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.Server
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "server_sync_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_sync_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  test "remote_commit from another node imports commit and updates in-memory doc", %{store: store} do
    uuid = "sync-test-#{:rand.uniform(1_000_000)}"

    # Create an initial commit so the Document.Server can start with content
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "SyncDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    # Start Document.Server for this UUID
    pid =
      start_supervised!(
        {Server, uuid: uuid, commit_store: store, client_id: 20},
        id: uuid
      )

    # Verify initial state
    assert Server.get_content(pid) == "hello"

    # Create a new commit simulating a remote node's changes
    # Build a doc that includes the initial state plus new text
    remote_doc = Yelixer.Doc.new(client_id: 99)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, initial_update)
    remote_doc = Commonplace.Document.ContentType.insert_text(remote_doc, 5, " world")
    remote_update = Yelixer.Encoding.encode_update(remote_doc)

    remote_commit = %Commonplace.Store.Commit{
      id: :crypto.hash(:sha256, remote_update),
      doc_uuid: uuid,
      parent_id: nil,
      update: remote_update,
      timestamp: DateTime.utc_now()
    }

    # Send the remote commit message directly to the Document.Server
    send(pid, {:remote_commit, remote_commit, :fake_remote_node})

    # Give the GenServer time to process the message
    # Use a synchronous call to ensure the handle_info has been processed
    _ = Server.get_doc(pid)

    # Verify the commit was imported into the CommitStore
    {:ok, stored_commit} = CommitStore.get_commit(store, remote_commit.id)
    assert stored_commit.id == remote_commit.id
    assert stored_commit.update == remote_update

    # Verify the Document.Server's in-memory doc was updated with the remote content
    content = Server.get_content(pid)
    assert content =~ "hello"
    assert content =~ "world"
  end

  test "remote_commit from self (Node.self()) is ignored", %{store: store} do
    uuid = "sync-self-#{:rand.uniform(1_000_000)}"

    # Create initial state
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "SelfTest")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "original")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    # Start Document.Server
    pid =
      start_supervised!(
        {Server, uuid: uuid, commit_store: store, client_id: 30},
        id: uuid
      )

    assert Server.get_content(pid) == "original"

    # Create a commit that would change the content
    modified_doc = Yelixer.Doc.new(client_id: 77)
    {:ok, modified_doc} = Yelixer.Encoding.apply_update(modified_doc, initial_update)
    modified_doc = Commonplace.Document.ContentType.insert_text(modified_doc, 8, " modified")
    modified_update = Yelixer.Encoding.encode_update(modified_doc)

    self_commit = %Commonplace.Store.Commit{
      id: :crypto.hash(:sha256, modified_update),
      doc_uuid: uuid,
      parent_id: nil,
      update: modified_update,
      timestamp: DateTime.utc_now()
    }

    # Send with Node.self() as source — should be ignored
    send(pid, {:remote_commit, self_commit, Node.self()})

    # Synchronize to ensure handle_info processed
    _ = Server.get_doc(pid)

    # The commit should NOT have been imported
    assert CommitStore.get_commit(store, self_commit.id) == :none

    # The in-memory doc should be unchanged
    assert Server.get_content(pid) == "original"
  end

  test "remote_commit with snapshot kind resets in-memory doc before apply (CX-u7p)",
       %{store: store} do
    uuid = "sync-snapshot-#{:rand.uniform(1_000_000)}"

    # Seed an initial commit so Document.Server starts with content.
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "SnapDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    # Start Document.Server — loads initial state into in-memory doc.
    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 20},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "hello"

    # Build a snapshot under a different client_id containing ONLY the
    # post-deletion observable state. If the server applied this on top
    # of its populated in-memory doc (without reset), content would
    # duplicate/resurrect. With the reset fix the server's doc matches
    # exactly what `DocBuilder.reconstruct_doc/2` produces.
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :text, "SnapDoc")
    snap_source = Commonplace.Document.ContentType.insert_text(snap_source, 0, "world")
    snap_update = Yelixer.Doc.snapshot_update(snap_source)

    snap_commit =
      CommitStore.create_snapshot_commit(store, uuid, snap_update)

    # Deliver the snapshot commit via the sync handle_info path. Mark
    # metadata.kind :snapshot (it already is — create_snapshot_commit
    # sets it; the commit fetched from the store carries it).
    {:ok, fetched_snap} = CommitStore.get_commit(store, snap_commit.id)
    assert fetched_snap.metadata.kind == :snapshot

    send(pid, {:remote_commit, fetched_snap, :fake_remote_node})

    # Synchronize via a call.
    _ = Commonplace.Document.Server.get_doc(pid)

    # The server's in-memory doc should match the full chain rebuild,
    # i.e. just the snapshot's content, not hello+world concatenated.
    {:ok, expected} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, uuid)
    expected_content = Commonplace.Document.ContentType.get_content(expected)

    assert Commonplace.Document.Server.get_content(pid) == expected_content
    assert Commonplace.Document.Server.get_content(pid) == "world"
  end

  test "non-snapshot remote commits still apply incrementally (regression guard)",
       %{store: store} do
    uuid = "sync-incremental-#{:rand.uniform(1_000_000)}"

    # Seed initial state
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "IncDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "aaa")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 21},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "aaa"

    # Build an incremental diff appending "bbb" (simulates a remote edit)
    remote_doc = Yelixer.Doc.new(client_id: 99)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, initial_update)
    remote_doc = Commonplace.Document.ContentType.insert_text(remote_doc, 3, "bbb")
    sv = Yelixer.BlockStore.state_vector(initial_doc.store)
    diff = Yelixer.Encoding.encode_diff(remote_doc, sv)

    inc_commit = %Commonplace.Store.Commit{
      id: :crypto.hash(:sha256, diff),
      doc_uuid: uuid,
      parent_id: initial_commit.id,
      update: diff,
      timestamp: DateTime.utc_now(),
      metadata: %{}
    }

    send(pid, {:remote_commit, inc_commit, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    assert Commonplace.Document.Server.get_content(pid) == "aaabbb"
  end

  test "remote snapshot that compacts our known head preserves uncommitted local edits (CX-u7p r2)",
       %{store: store} do
    uuid = "sync-snap-preserve-#{:rand.uniform(1_000_000)}"

    # Seed a committed state containing "hello".
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "DirtyDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    # Start the server. Its `state.parent_commit` = initial_commit.id, and
    # state.doc materializes "hello".
    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 20},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "hello"

    # Simulate a pending local edit — applied to state.doc but NOT yet committed.
    :ok = Commonplace.Document.Server.insert_text(pid, 5, " local")
    assert Commonplace.Document.Server.get_content(pid) == "hello local"

    # A remote peer produces a compaction snapshot of the committed chain
    # — i.e. a snapshot whose materialized content matches the committed
    # state ("hello"), chained to initial_commit.
    peer_doc = Yelixer.Doc.new(client_id: 77)
    {:ok, peer_doc} = Yelixer.Encoding.apply_update(peer_doc, initial_update)
    snap_update = Yelixer.Doc.snapshot_update(peer_doc)

    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    assert snap_commit.parent_id == initial_commit.id

    {:ok, fetched_snap} = CommitStore.get_commit(store, snap_commit.id)
    assert fetched_snap.metadata.kind == :snapshot

    # Deliver via the remote-commit path.
    send(pid, {:remote_commit, fetched_snap, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # The pending local edit must survive — the snapshot is a logical
    # no-op relative to the committed head, and the reset path would have
    # silently dropped " local".
    assert Commonplace.Document.Server.get_content(pid) == "hello local"
  end

  test "remote snapshot with divergent content still triggers reset (CX-u7p r2)",
       %{store: store} do
    uuid = "sync-snap-divergent-#{:rand.uniform(1_000_000)}"

    # Seed a committed state containing "aaa".
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "DivergentDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "aaa")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 30},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "aaa"

    # A remote peer produces a snapshot whose content DIFFERS from our
    # committed state (e.g., a compaction of a divergent branch rebased
    # onto our head). snapshot_is_noop? must return false here, and the
    # reset path must run so the server converges on the snapshot.
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :text, "DivergentDoc")
    snap_source = Commonplace.Document.ContentType.insert_text(snap_source, 0, "zzz")
    snap_update = Yelixer.Doc.snapshot_update(snap_source)

    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    {:ok, fetched_snap} = CommitStore.get_commit(store, snap_commit.id)

    send(pid, {:remote_commit, fetched_snap, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # The server should now reflect the snapshot's content, not the
    # committed "aaa" — confirming the reset path ran.
    assert Commonplace.Document.Server.get_content(pid) == "zzz"
  end

  test "apply_with_base advances parent_commit to the applied commit id (CX-u7p r3 P1)",
       %{store: store} do
    # Focused unit test for the round-3 P1 fix: apply_with_base/3 must
    # update state.parent_commit = commit.id whenever it advances
    # state.doc, so that a subsequent snapshot_is_noop?/2 check compares
    # against the actual head that has been incorporated (not the last
    # locally-committed head). Pre-fix, state.parent_commit stayed
    # pinned to the last local commit even as state.doc advanced.
    uuid = "sync-parent-track-#{:rand.uniform(1_000_000)}"

    # Seed committed state A.
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "TrackDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    commit_a = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 20},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "hello"
    assert :sys.get_state(pid).parent_commit == commit_a.id

    # Remote delta B: incremental diff appending " world".
    remote_doc = Yelixer.Doc.new(client_id: 99)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, initial_update)
    remote_doc = Commonplace.Document.ContentType.insert_text(remote_doc, 5, " world")
    sv = Yelixer.BlockStore.state_vector(initial_doc.store)
    diff = Yelixer.Encoding.encode_diff(remote_doc, sv)

    commit_b = %Commonplace.Store.Commit{
      id: :crypto.hash(:sha256, diff),
      doc_uuid: uuid,
      parent_id: commit_a.id,
      update: diff,
      timestamp: DateTime.utc_now(),
      metadata: %{}
    }

    send(pid, {:remote_commit, commit_b, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # state.doc advanced...
    assert Commonplace.Document.Server.get_content(pid) == "hello world"
    # ...AND state.parent_commit advanced to B (the P1 fix).
    assert :sys.get_state(pid).parent_commit == commit_b.id
  end

  test "remote delta then compaction snapshot preserves dirty local edits (CX-u7p r3)",
       %{store: store} do
    # End-to-end scenario from the round-3 finding:
    #   server at A → remote delta B → dirty local edit → snapshot(B)
    # Assertion: the dirty local edit must survive.
    #
    # Pre-fix, state.parent_commit stayed pinned at A even after B was
    # applied, so when the snapshot(parent=B) arrived snapshot_is_noop?
    # compared B ≠ A and classified it as divergent, triggering the
    # reset path and silently dropping the dirty edit.
    uuid = "sync-delta-then-snap-#{:rand.uniform(1_000_000)}"

    # Seed committed state A = "hello".
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "DeltaDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _commit_a = CommitStore.create_commit(store, uuid, initial_update, nil)

    # Start the server at A. state.doc = "hello", state.parent_commit = A.
    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 20},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "hello"

    # Remote delta B = A + " world", durably stored (chained on A, :latest
    # advances to B) so reconstruct_doc_at/3 can later find B in the chain.
    # This mirrors the post-sync durable-store state for this scenario.
    remote_doc = Yelixer.Doc.new(client_id: 99)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, initial_update)
    remote_doc = Commonplace.Document.ContentType.insert_text(remote_doc, 5, " world")
    sv = Yelixer.BlockStore.state_vector(initial_doc.store)
    diff = Yelixer.Encoding.encode_diff(remote_doc, sv)
    commit_b = CommitStore.create_chained_commit(store, uuid, diff)

    # Deliver B to the server via the remote-commit path. import_commit
    # sees B already exists (no-op), but apply_with_base still applies
    # the diff onto state.doc and — per the P1 fix — advances
    # state.parent_commit from A to B.
    send(pid, {:remote_commit, commit_b, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    assert Commonplace.Document.Server.get_content(pid) == "hello world"
    assert :sys.get_state(pid).parent_commit == commit_b.id

    # Dirty local edit (not committed).
    :ok = Commonplace.Document.Server.insert_text(pid, 11, "!")
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"

    # Remote peer sends a compaction snapshot of B (same materialized
    # content, fresh encoding), chained on B. Because commit.parent_id
    # matches state.parent_commit AND reconstruct_doc_at(B) == snap
    # content, snapshot_is_noop?/2 returns true and the dirty "!" is
    # preserved.
    peer_doc = Yelixer.Doc.new(client_id: 77)
    {:ok, peer_doc} = Yelixer.Encoding.apply_update(peer_doc, initial_update)
    {:ok, peer_doc} = Yelixer.Encoding.apply_update(peer_doc, diff)
    snap_update = Yelixer.Doc.snapshot_update(peer_doc)

    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    assert snap_commit.parent_id == commit_b.id
    {:ok, fetched_snap} = CommitStore.get_commit(store, snap_commit.id)
    assert fetched_snap.metadata.kind == :snapshot

    send(pid, {:remote_commit, fetched_snap, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # The dirty "!" must survive...
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"
    # ...and parent_commit advances to the snapshot (CX-u7p r4: keep the
    # snapshot on the active chain so subsequent local commits chain onto
    # it, not onto B — otherwise the snapshot becomes a sibling of the
    # next local commit and falls off the history the reconstruct walk
    # follows).
    assert :sys.get_state(pid).parent_commit == snap_commit.id

    # Regression: commit the dirty edit and verify it chains onto the
    # snapshot (not onto B). This is the outcome codex-r4 flagged: without
    # advancing parent_commit in the no-op branch, the local commit would
    # be a child of B, making the snapshot a sibling and orphaning it
    # from the reconstruct walk.
    {:ok, local_commit} = Commonplace.Document.Server.commit(pid)
    assert local_commit.parent_id == snap_commit.id
  end

  test "snapshot chained on a delta that arrived only via broadcast preserves dirty edits (CX-u7p r6)",
       %{store: store} do
    # Mirror the real wire path: a remote peer broadcasts a delta. Our
    # server's import_commit/2 stores it but does NOT advance :latest
    # (to avoid clobbering local heads during catch-up). Without the r6
    # fix (advance :latest in apply_with_base/3), a later snapshot whose
    # parent is that imported delta would fail the snapshot_is_noop?
    # check — reconstruct_doc_at walks from :latest, can't reach the
    # imported delta, returns :none, and the reset path drops dirty
    # local edits.
    uuid = "sync-broadcast-snap-#{:rand.uniform(1_000_000)}"

    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "BcastDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    commit_a = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 20},
        id: uuid
      )

    assert :sys.get_state(pid).parent_commit == commit_a.id

    # Remote peer builds delta B = A + " world" and broadcasts it. Build
    # the Commit without touching the store via create_chained_commit/3
    # so :latest stays at A — this is what the real broadcast path looks
    # like from this node's perspective.
    remote_doc = Yelixer.Doc.new(client_id: 99)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, initial_update)
    remote_doc = Commonplace.Document.ContentType.insert_text(remote_doc, 5, " world")
    sv = Yelixer.BlockStore.state_vector(initial_doc.store)
    diff = Yelixer.Encoding.encode_diff(remote_doc, sv)
    commit_b = Commonplace.Store.Commit.new(uuid, diff, commit_a.id, %{})

    send(pid, {:remote_commit, commit_b, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    assert Commonplace.Document.Server.get_content(pid) == "hello world"
    # r6: apply_with_base must advance :latest so the next snapshot check
    # can walk the chain and find B.
    {:ok, latest_after_b} = CommitStore.latest_commit(store, uuid)
    assert latest_after_b.id == commit_b.id

    # Dirty local edit (uncommitted).
    :ok = Commonplace.Document.Server.insert_text(pid, 11, "!")
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"

    # Peer sends a compaction snapshot of B, also only via broadcast.
    peer_doc = Yelixer.Doc.new(client_id: 77)
    {:ok, peer_doc} = Yelixer.Encoding.apply_update(peer_doc, initial_update)
    {:ok, peer_doc} = Yelixer.Encoding.apply_update(peer_doc, diff)
    snap_update = Yelixer.Doc.snapshot_update(peer_doc)
    snap_commit = Commonplace.Store.Commit.new(uuid, snap_update, commit_b.id, %{kind: :snapshot})

    send(pid, {:remote_commit, snap_commit, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # Dirty "!" survives the snapshot because snapshot_is_noop? was able
    # to reach B through the store chain.
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"
    assert :sys.get_state(pid).parent_commit == snap_commit.id
  end

  test "repeated no-op snapshots advance :latest so subsequent snapshot_is_noop? checks find the head (CX-u7p r5)",
       %{store: store} do
    uuid = "sync-repeat-snap-#{:rand.uniform(1_000_000)}"

    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "Doc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    commit_a = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 20},
        id: uuid
      )

    assert :sys.get_state(pid).parent_commit == commit_a.id

    # Dirty local edit (uncommitted).
    :ok = Commonplace.Document.Server.insert_text(pid, 5, "!")
    assert Commonplace.Document.Server.get_content(pid) == "hello!"

    # Peer snapshot 1 of the committed state A (chained on A). It is a
    # no-op relative to state.doc-excluding-dirty, so dirty "!" survives.
    peer_doc1 = Yelixer.Doc.new(client_id: 77)
    {:ok, peer_doc1} = Yelixer.Encoding.apply_update(peer_doc1, initial_update)
    snap1_update = Yelixer.Doc.snapshot_update(peer_doc1)
    snap1 = CommitStore.create_snapshot_commit(store, uuid, snap1_update)
    {:ok, fetched1} = CommitStore.get_commit(store, snap1.id)
    send(pid, {:remote_commit, fetched1, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    assert Commonplace.Document.Server.get_content(pid) == "hello!"
    assert :sys.get_state(pid).parent_commit == snap1.id
    # :latest must advance too — otherwise commit_log walks back from A
    # and a second snapshot check can't find snap1 in the chain.
    {:ok, latest_after_snap1} = CommitStore.latest_commit(store, uuid)
    assert latest_after_snap1.id == snap1.id

    # Peer snapshot 2, chained on snap1. Must also be recognized as a
    # no-op (same materialized content), which requires reconstruct_doc_at
    # to reach snap1 from :latest.
    #
    # snap1 is already a self-contained update encoding the full "hello"
    # state, so a fresh peer replica only needs to apply snap1 (applying
    # initial_update on top would duplicate the content to "hellohello"
    # because snapshot IDs are fresh and Yjs sees them as new items).
    peer_doc2 = Yelixer.Doc.new(client_id: 88)
    {:ok, peer_doc2} = Yelixer.Encoding.apply_update(peer_doc2, snap1_update)
    snap2_update = Yelixer.Doc.snapshot_update(peer_doc2)

    snap2 = CommitStore.create_snapshot_commit(store, uuid, snap2_update)
    assert snap2.parent_id == snap1.id
    {:ok, fetched2} = CommitStore.get_commit(store, snap2.id)
    send(pid, {:remote_commit, fetched2, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # Dirty "!" must still survive the second snapshot — this is what
    # fails if :latest didn't advance after snap1 (codex-r5 P1).
    assert Commonplace.Document.Server.get_content(pid) == "hello!"
    assert :sys.get_state(pid).parent_commit == snap2.id
    {:ok, latest_after_snap2} = CommitStore.latest_commit(store, uuid)
    assert latest_after_snap2.id == snap2.id
  end

  test "remote_commit with invalid update does not crash the server", %{store: store} do
    uuid = "sync-bad-#{:rand.uniform(1_000_000)}"

    # Create initial state
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "BadUpdate")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "stable")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Server, uuid: uuid, commit_store: store, client_id: 40},
        id: uuid
      )

    assert Server.get_content(pid) == "stable"

    # Send a commit with garbage update data
    bad_commit = %Commonplace.Store.Commit{
      id: :crypto.hash(:sha256, "garbage"),
      doc_uuid: uuid,
      parent_id: nil,
      update: <<0xFF, 0xFE, 0xFD, 0xFC>>,
      timestamp: DateTime.utc_now()
    }

    send(pid, {:remote_commit, bad_commit, :fake_remote_node})

    # Synchronize and verify the server is still alive and content unchanged
    assert Server.get_content(pid) == "stable"
    assert Process.alive?(pid)
  end
end
