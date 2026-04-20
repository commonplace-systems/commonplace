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

    remote_commit = Commonplace.Store.Commit.new(uuid, remote_update, nil)

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

    self_commit = Commonplace.Store.Commit.new(uuid, modified_update, nil)

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
    {snap_update, _dm} = Yelixer.Doc.snapshot_update(snap_source)

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

    inc_commit = Commonplace.Store.Commit.new(uuid, diff, initial_commit.id)

    send(pid, {:remote_commit, inc_commit, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    assert Commonplace.Document.Server.get_content(pid) == "aaabbb"
  end

  test "snapshot arrival preserves local dirty YText edits via positional rebase (CX-dqn)",
       %{store: store} do
    uuid = "sync-rebase-#{:rand.uniform(1_000_000)}"

    # Seed initial committed state: "hello"
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "RebaseDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 42},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "hello"

    # Local dirty edit: append " world" (no commit — this is uncommitted)
    :ok = Commonplace.Document.Server.insert_text(pid, 5, " world")
    assert Commonplace.Document.Server.get_content(pid) == "hello world"

    # Remote sends a snapshot whose observable content is "hello!"
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :text, "RebaseDoc")
    snap_source = Commonplace.Document.ContentType.insert_text(snap_source, 0, "hello!")
    {snap_update, _dm} = Yelixer.Doc.snapshot_update(snap_source)
    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    {:ok, fetched} = CommitStore.get_commit(store, snap_commit.id)

    send(pid, {:remote_commit, fetched, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # Diff(pre, dirty) = [{:insert, 5, " world"}]. Applied to new_doc "hello!":
    # insert " world" at pos 5 of "hello!" → "hello world!"
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"
  end

  test "snapshot arrival after remote incremental does not double-apply (CX-bgq)",
       %{store: store} do
    uuid = "sync-bgq-#{:rand.uniform(1_000_000)}"

    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "BgqDoc")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 50},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == "hello"

    # Remote incremental commit adds " world" at pos 5 (chains off C1).
    remote_doc = Yelixer.Doc.new(client_id: 99)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, initial_update)
    remote_doc = Commonplace.Document.ContentType.insert_text(remote_doc, 5, " world")
    sv = Yelixer.BlockStore.state_vector(initial_doc.store)
    diff = Yelixer.Encoding.encode_diff(remote_doc, sv)

    inc_commit = Commonplace.Store.Commit.new(uuid, diff, initial_commit.id)

    send(pid, {:remote_commit, inc_commit, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    assert Commonplace.Document.Server.get_content(pid) == "hello world"

    # Local dirty edit: append "!" (uncommitted).
    :ok = Commonplace.Document.Server.insert_text(pid, 11, "!")
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"

    # Remote snapshot arrives whose observable content is "hello world"
    # (the already-incorporated compacted state from C1+C2).
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :text, "BgqDoc")
    snap_source = Commonplace.Document.ContentType.insert_text(snap_source, 0, "hello world")
    {snap_update, _dm} = Yelixer.Doc.snapshot_update(snap_source)
    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    {:ok, fetched} = CommitStore.get_commit(store, snap_commit.id)

    send(pid, {:remote_commit, fetched, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # Pre-fix: parent_commit stayed at C1 across the incremental apply, so
    # reconstruct_at(C1)="hello"; diff("hello","hello world!") = insert
    # " world!" at 5; replayed on new_doc "hello world" → "hello world world!".
    # Post-fix: parent_commit advances to inc_commit.id, so reconstruct yields
    # "hello world"; diff = insert "!" at 11 → "hello world!".
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"
  end

  test "snapshot arrival preserves local dirty YMap edits via positional rebase (CX-8nu)",
       %{store: store} do
    uuid = "sync-ymap-#{:rand.uniform(1_000_000)}"

    # Seed initial committed map: %{"a" => "1", "b" => "2"}
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :map, "MapDoc")
    initial_doc = Commonplace.Document.ContentType.set_key(initial_doc, "a", "1")
    initial_doc = Commonplace.Document.ContentType.set_key(initial_doc, "b", "2")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 60},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == %{"a" => "1", "b" => "2"}

    # Local dirty edits: add "c", remove "b", modify "a" (uncommitted).
    :ok = Commonplace.Document.Server.set_key(pid, "c", "3")
    :ok = Commonplace.Document.Server.set_key(pid, "a", "one")
    :ok = Commonplace.Document.Server.delete_key(pid, "b")

    assert Commonplace.Document.Server.get_content(pid) == %{"a" => "one", "c" => "3"}

    # Remote snapshot with %{"a" => "1", "b" => "2", "d" => "4"} (concurrent add).
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :map, "MapDoc")
    snap_source = Commonplace.Document.ContentType.set_key(snap_source, "a", "1")
    snap_source = Commonplace.Document.ContentType.set_key(snap_source, "b", "2")
    snap_source = Commonplace.Document.ContentType.set_key(snap_source, "d", "4")
    {snap_update, _dm} = Yelixer.Doc.snapshot_update(snap_source)
    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    {:ok, fetched} = CommitStore.get_commit(store, snap_commit.id)

    send(pid, {:remote_commit, fetched, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # Rebase replays (add "c", remove "b", modify "a" to "one") onto
    # new_doc %{"a" => "1", "b" => "2", "d" => "4"}:
    #   a modified: "1" → "one"
    #   b removed
    #   c added: "3"
    #   d (remote-only) preserved
    assert Commonplace.Document.Server.get_content(pid) ==
             %{"a" => "one", "c" => "3", "d" => "4"}
  end

  test "snapshot arrival preserves local dirty YArray edits via positional rebase (CX-1cc)",
       %{store: store} do
    uuid = "sync-yarray-#{:rand.uniform(1_000_000)}"

    # Seed initial committed array: [1, 2, 3]
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :array, "ArrayDoc")
    initial_doc = Commonplace.Document.ContentType.push_items(initial_doc, [1, 2, 3])
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 61},
        id: uuid
      )

    assert Commonplace.Document.Server.get_content(pid) == [1, 2, 3]

    # Local dirty edits: insert 9 between 2 and 3, then append 4.
    # Intended result: [1, 2, 9, 3, 4] (uncommitted).
    :ok = Commonplace.Document.Server.insert_items(pid, 2, [9])
    :ok = Commonplace.Document.Server.push_items(pid, [4])

    assert Commonplace.Document.Server.get_content(pid) == [1, 2, 9, 3, 4]

    # Remote snapshot with [1, 2, 3, 99] (concurrent append).
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :array, "ArrayDoc")
    snap_source = Commonplace.Document.ContentType.push_items(snap_source, [1, 2, 3, 99])
    {snap_update, _dm} = Yelixer.Doc.snapshot_update(snap_source)
    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    {:ok, fetched} = CommitStore.get_commit(store, snap_commit.id)

    send(pid, {:remote_commit, fetched, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # Rebase replays (insert 9 at 2, append 4) onto new_doc [1, 2, 3, 99]:
    #   diff(pre=[1,2,3], dirty=[1,2,9,3,4]) = eq[1,2] ins[9] eq[3] ins[4]
    #   applied to [1,2,3,99]:
    #     ins 9 at pos 2 → [1,2,9,3,99]
    #     ins 4 at pos 4 → [1,2,9,3,4,99]  ← positional: dirty's "append" lands
    #                                        before the remote's concurrent append.
    #   This is the documented positional-rebase tradeoff (RFC §Explicit Tradeoffs).
    assert Commonplace.Document.Server.get_content(pid) == [1, 2, 9, 3, 4, 99]
  end

  test "snapshot arrival preserves local dirty YXml edits via positional rebase (CX-9fy)",
       %{store: store} do
    alias Yelixer.Types.{XMLFragment, XMLElement}

    uuid = "sync-yxml-#{:rand.uniform(1_000_000)}"

    # Seed initial committed XML: <p>  (one element, no attrs, no children)
    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :xml, "XmlDoc")
    initial_doc = XMLFragment.insert_child(initial_doc, "content", 0, {:element, "p"})
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 62},
        id: uuid
      )

    # Local dirty edits: set an attribute on the p element.
    doc_before = Commonplace.Document.Server.get_doc(pid)
    [{:element, _, p_name}] = XMLFragment.to_list(doc_before, "content")
    dirty_doc = XMLElement.set_attribute(doc_before, p_name, "class", "dirty")
    dirty_update = Yelixer.Encoding.encode_update(dirty_doc)
    :ok = Commonplace.Document.Server.apply_update(pid, dirty_update)

    assert Commonplace.Document.Server.get_content(pid) ==
             [{:element, "p", %{"class" => "dirty"}, []}]

    # Remote snapshot adds a sibling <q> element (concurrent structural change).
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :xml, "XmlDoc")
    snap_source = XMLFragment.insert_child(snap_source, "content", 0, {:element, "p"})
    snap_source = XMLFragment.insert_child(snap_source, "content", 1, {:element, "q"})
    {snap_update, _dm} = Yelixer.Doc.snapshot_update(snap_source)
    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    {:ok, fetched} = CommitStore.get_commit(store, snap_commit.id)

    send(pid, {:remote_commit, fetched, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # Rebase applies the dirty attribute set onto the matched <p> in new_doc [p, q].
    assert Commonplace.Document.Server.get_content(pid) ==
             [
               {:element, "p", %{"class" => "dirty"}, []},
               {:element, "q", %{}, []}
             ]
  end

  test "snapshot arrival aborts when dirty-edit rebase is out-of-range (all-or-nothing)",
       %{store: store} do
    uuid = "sync-rebase-abort-#{:rand.uniform(1_000_000)}"

    initial_doc = Yelixer.Doc.new(client_id: 10)
    initial_doc = Commonplace.Document.ContentType.create(initial_doc, :text, "RebaseAbort")
    initial_doc = Commonplace.Document.ContentType.insert_text(initial_doc, 0, "hello world")
    initial_update = Yelixer.Encoding.encode_update(initial_doc)
    _initial_commit = CommitStore.create_commit(store, uuid, initial_update, nil)

    pid =
      start_supervised!(
        {Commonplace.Document.Server, uuid: uuid, commit_store: store, client_id: 43},
        id: uuid
      )

    # Dirty edit appends "!" at pos 11.
    :ok = Commonplace.Document.Server.insert_text(pid, 11, "!")
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"

    # Remote snapshot drastically shortens to "hi" — pos 11 is now OOR.
    snap_source = Yelixer.Doc.new(client_id: 77)
    snap_source = Commonplace.Document.ContentType.create(snap_source, :text, "RebaseAbort")
    snap_source = Commonplace.Document.ContentType.insert_text(snap_source, 0, "hi")
    {snap_update, _dm} = Yelixer.Doc.snapshot_update(snap_source)
    snap_commit = CommitStore.create_snapshot_commit(store, uuid, snap_update)
    {:ok, fetched} = CommitStore.get_commit(store, snap_commit.id)

    send(pid, {:remote_commit, fetched, :fake_remote_node})
    _ = Commonplace.Document.Server.get_doc(pid)

    # All-or-nothing: snapshot application is aborted, local dirty state preserved.
    assert Commonplace.Document.Server.get_content(pid) == "hello world!"
    assert Process.alive?(pid)
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

    # Send a commit with garbage update data (properly content-addressed
    # so the CX-gwz id-verification gate passes and the commit reaches
    # the apply_update path where the garbage bytes fail).
    bad_commit = Commonplace.Store.Commit.new(uuid, <<0xFF, 0xFE, 0xFD, 0xFC>>, nil)

    send(pid, {:remote_commit, bad_commit, :fake_remote_node})

    # Synchronize and verify the server is still alive and content unchanged
    assert Server.get_content(pid) == "stable"
    assert Process.alive?(pid)
  end
end
