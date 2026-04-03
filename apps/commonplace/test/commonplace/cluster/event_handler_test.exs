defmodule Commonplace.Cluster.EventHandlerTest do
  @moduledoc """
  Tests for EventHandler's active_doc_uuids/0 function which queries
  the Commonplace.Document.Registry.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.Server
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "event_handler_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_eh_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  defp active_doc_uuids do
    Registry.select(Commonplace.Document.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  test "started Document.Server appears in registry, stopped one disappears", %{store: store} do
    uuid = "registry-test-#{:rand.uniform(1_000_000)}"

    # UUID should not be in the registry before starting
    uuids_before = active_doc_uuids()
    refute uuid in uuids_before

    # Start a Document.Server for this UUID
    pid =
      start_supervised!(
        {Server, uuid: uuid, commit_store: store, client_id: 1},
        id: uuid
      )

    # UUID should now appear in the registry
    uuids_during = active_doc_uuids()
    assert uuid in uuids_during

    # Stop the Document.Server
    stop_supervised!(uuid)

    # Wait briefly for registry cleanup
    Process.sleep(50)

    # UUID should be gone from the registry
    uuids_after = active_doc_uuids()
    refute uuid in uuids_after

    # Also verify the process is no longer alive
    refute Process.alive?(pid)
  end

  test "multiple Document.Servers all appear in registry", %{store: store} do
    uuid1 = "registry-multi-1-#{:rand.uniform(1_000_000)}"
    uuid2 = "registry-multi-2-#{:rand.uniform(1_000_000)}"
    uuid3 = "registry-multi-3-#{:rand.uniform(1_000_000)}"

    _pid1 =
      start_supervised!(
        {Server, uuid: uuid1, commit_store: store, client_id: 1},
        id: uuid1
      )

    _pid2 =
      start_supervised!(
        {Server, uuid: uuid2, commit_store: store, client_id: 2},
        id: uuid2
      )

    _pid3 =
      start_supervised!(
        {Server, uuid: uuid3, commit_store: store, client_id: 3},
        id: uuid3
      )

    uuids = active_doc_uuids()
    assert uuid1 in uuids
    assert uuid2 in uuids
    assert uuid3 in uuids

    # Stop one, verify the other two remain
    stop_supervised!(uuid2)
    Process.sleep(50)

    uuids_after = active_doc_uuids()
    assert uuid1 in uuids_after
    refute uuid2 in uuids_after
    assert uuid3 in uuids_after
  end

  test "registry lookup by UUID returns the correct pid", %{store: store} do
    uuid = "registry-lookup-#{:rand.uniform(1_000_000)}"

    pid =
      start_supervised!(
        {Server, uuid: uuid, commit_store: store, client_id: 1},
        id: uuid
      )

    # Registry.lookup should find our pid
    assert [{^pid, _}] = Registry.lookup(Commonplace.Document.Registry, uuid)
  end
end
