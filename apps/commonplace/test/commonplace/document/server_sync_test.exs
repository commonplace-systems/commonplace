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
