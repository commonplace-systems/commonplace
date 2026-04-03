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
end
