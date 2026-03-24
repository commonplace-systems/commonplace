defmodule Commonplace.Store.CommitPubsubTest do
  use ExUnit.Case

  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "pubsub_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_pubsub_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  test "create_commit broadcasts on PubSub", %{store: store} do
    uuid = "test-uuid-#{:rand.uniform(1_000_000)}"
    Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")

    doc = Yelixer.Doc.new()
    update = Yelixer.Encoding.encode_update(doc)
    commit = CommitStore.create_commit(store, uuid, update, nil)

    assert_receive {:commit, ^uuid, commit_id}, 1000
    assert commit_id == commit.id
  end

  test "create_chained_commit broadcasts on PubSub", %{store: store} do
    uuid = "test-uuid-#{:rand.uniform(1_000_000)}"

    doc = Yelixer.Doc.new()
    update = Yelixer.Encoding.encode_update(doc)
    _first = CommitStore.create_commit(store, uuid, update, nil)

    Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")

    second = CommitStore.create_chained_commit(store, uuid, update)

    assert_receive {:commit, ^uuid, commit_id}, 1000
    assert commit_id == second.id
  end

  test "message includes uuid and commit_id", %{store: store} do
    uuid = "test-uuid-#{:rand.uniform(1_000_000)}"
    Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")

    doc = Yelixer.Doc.new()
    update = Yelixer.Encoding.encode_update(doc)
    commit = CommitStore.create_commit(store, uuid, update, nil)

    assert_receive {:commit, received_uuid, received_commit_id}, 1000
    assert received_uuid == uuid
    assert received_commit_id == commit.id
  end
end
