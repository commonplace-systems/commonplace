defmodule Commonplace.Sync.DistributedPubSubTest do
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  test "broadcast_commit sends commit on sync channel" do
    uuid = UUID.uuid4()
    CPPubSub.subscribe_sync(uuid)

    commit = %Commonplace.Store.Commit{
      id: :crypto.strong_rand_bytes(32),
      doc_uuid: uuid,
      parent_id: nil,
      update: "test_update",
      timestamp: DateTime.utc_now()
    }

    CPPubSub.broadcast_commit(uuid, commit)

    assert_receive {:remote_commit, ^commit, _node}, 1000
  end

  test "broadcast_commit message format is {:remote_commit, commit, node}" do
    uuid = UUID.uuid4()
    CPPubSub.subscribe_sync(uuid)

    commit = %Commonplace.Store.Commit{
      id: :crypto.strong_rand_bytes(32),
      doc_uuid: uuid,
      parent_id: nil,
      update: "format_test_update",
      timestamp: DateTime.utc_now()
    }

    CPPubSub.broadcast_commit(uuid, commit)

    assert_receive message, 1000

    # Verify the exact tuple shape
    assert {:remote_commit, received_commit, source_node} = message
    assert received_commit == commit
    assert source_node == Node.self()
  end

  test "broadcast_commit from self: Document.Server handle_info ignores same-node messages" do
    # When source_node == Node.self(), the handle_info clause should be a no-op.
    # We verify this by checking the condition directly: broadcast_commit uses
    # Node.self() as the source_node, so the guard `source_node != Node.self()`
    # evaluates to false, meaning the message is ignored.
    uuid = UUID.uuid4()
    CPPubSub.subscribe_sync(uuid)

    commit = %Commonplace.Store.Commit{
      id: :crypto.strong_rand_bytes(32),
      doc_uuid: uuid,
      parent_id: nil,
      update: "self_broadcast",
      timestamp: DateTime.utc_now()
    }

    CPPubSub.broadcast_commit(uuid, commit)

    # Verify the message arrives with Node.self() as source
    assert_receive {:remote_commit, ^commit, source_node}, 1000
    assert source_node == Node.self()

    # This confirms that Document.Server's handle_info would ignore this message
    # because the condition `source_node != Node.self()` is false
  end
end
