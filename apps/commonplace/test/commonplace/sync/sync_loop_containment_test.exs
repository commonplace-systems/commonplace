defmodule Commonplace.Sync.SyncLoopContainmentTest do
  @moduledoc """
  CX-xmhw: a Sync.Agent crash must be CONTAINED, not cascade. The reproduced
  field failure was `bartleby Port exit_status 0 → Sync.Agent crash →
  Application exits :stopped`: a user-process lifecycle event propagated up an
  un-isolated link chain into the app supervisor and took down the BEAM.

  SyncLoop starts its Sync.Agent with a bare `start_link` (linked, no trap_exit),
  so an agent crash kills the loop — and from there it can climb to whatever
  started the loop. The fix isolates that boundary: the loop monitors (not links)
  its agent and handles the crash, so the agent's death never propagates.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Sync.SyncLoop
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_syncloop_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"syncloop_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    sync_dir = Path.join(dir, "workspace")
    File.mkdir_p!(sync_dir)

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, root: root_uuid, sync_dir: sync_dir}
  end

  test "a Sync.Agent crash is contained — the SyncLoop survives and recovers (CX-xmhw)",
       %{store: store, root: root, sync_dir: sync_dir} do
    # A long interval so the periodic tick doesn't interfere with the test.
    {:ok, loop} =
      SyncLoop.start_link(dir: sync_dir, root_uuid: root, store: store, interval: 60_000)

    Process.sleep(100)

    %{agent_pid: agent} = :sys.get_state(loop)
    assert Process.alive?(agent)

    # Simulate the Sync.Agent crashing (a realistic, trappable non-:kill reason —
    # the way a sync_once failure or a linked child death would surface).
    Process.exit(agent, :simulated_agent_crash)
    Process.sleep(300)

    # Containment: the agent's crash must NOT have taken the loop down with it
    # (that is the link cascade that reached the app supervisor in the field).
    assert Process.alive?(loop),
           "SyncLoop died when its Sync.Agent crashed — the crash cascaded instead of being contained"

    # Recovery: the loop re-established a live agent so sync continues.
    %{agent_pid: new_agent} = :sys.get_state(loop)
    assert Process.alive?(new_agent)
    assert new_agent != agent

    GenServer.stop(loop)
  end
end
