defmodule Commonplace.Dataflow.RedLogTest do
  @moduledoc """
  Tests for persistent red event logs — the magenta→red onramp.
  """
  use ExUnit.Case

  alias Commonplace.Dataflow.{Magenta, RedLog}
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  describe "manual append and read" do
    test "append events and read them back", %{store: store} do
      log_uuid = "log-#{UUID.uuid4()}"
      log = RedLog.new(log_uuid, store)

      msg1 = Magenta.message("start", "orchestrator", %{process: "bartleby"})
      msg2 = Magenta.message("stop", "cli", %{reason: "shutdown"})

      log = RedLog.append(log, msg1)
      log = RedLog.append(log, msg2)

      events = RedLog.read(log)
      assert length(events) == 2
      assert Enum.at(events, 0)["type"] == "start"
      assert Enum.at(events, 1)["type"] == "stop"
    end

    test "events persist through commit and reload", %{store: store} do
      log_uuid = "log-#{UUID.uuid4()}"
      log = RedLog.new(log_uuid, store)

      msg = Magenta.message("deploy", "ci", %{version: "1.0"})
      log = RedLog.append(log, msg)
      RedLog.commit(log)

      # Reload from store
      log2 = RedLog.load(log_uuid, store)
      events = RedLog.read(log2)
      assert length(events) == 1
      assert Enum.at(events, 0)["type"] == "deploy"
      assert Enum.at(events, 0)["source"] == "ci"
      assert Enum.at(events, 0)["payload"]["version"] == "1.0"
    end

    test "events accumulate across multiple commits", %{store: store} do
      log_uuid = "log-#{UUID.uuid4()}"
      log = RedLog.new(log_uuid, store)

      log = RedLog.append(log, Magenta.message("event-1", "a", %{}))
      RedLog.commit(log)

      log = RedLog.load(log_uuid, store)
      log = RedLog.append(log, Magenta.message("event-2", "b", %{}))
      RedLog.commit(log)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)
      assert length(events) == 2
      types = Enum.map(events, & &1["type"])
      assert types == ["event-1", "event-2"]
    end
  end

  describe "stable client_id (CX-pyi)" do
    test "100 load → append → commit cycles produce a state vector with one client_id",
         %{store: store} do
      log_uuid = "log-#{UUID.uuid4()}"
      log = RedLog.new(log_uuid, store)
      RedLog.commit(log)

      for n <- 1..100 do
        log = RedLog.load(log_uuid, store)
        log = RedLog.append(log, Magenta.message("e#{n}", "src", %{i: n}))
        RedLog.commit(log)
      end

      {:ok, commit} = CommitStore.latest_commit(store, log_uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

      sv = Yelixer.BlockStore.state_vector(doc.store)
      assert map_size(sv.clocks) == 1,
             "expected single stable client_id in state vector after 100 cycles, got #{map_size(sv.clocks)}: #{inspect(Map.keys(sv.clocks))}"

      expected_client_id = :erlang.phash2(log_uuid, 0xFFFF_FFFF)
      assert Map.has_key?(sv.clocks, expected_client_id),
             "state vector should contain phash2-derived client_id #{expected_client_id}"

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)
      assert length(events) == 100
    end
  end

  describe "magenta→red onramp" do
    test "subscribes to magenta topic and persists messages", %{store: store} do
      log_uuid = "log-#{UUID.uuid4()}"
      topic = "test/onramp/#{:rand.uniform(1_000_000)}"

      {:ok, pid} = RedLog.start_onramp(log_uuid, topic, store)

      # Send magenta messages
      Magenta.send(topic, Magenta.message("alpha", "sender-1", %{}))
      Magenta.send(topic, Magenta.message("beta", "sender-2", %{x: 1}))

      # Give the onramp time to process
      Process.sleep(50)

      # Commit and read
      RedLog.commit_onramp(pid)
      Process.sleep(50)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)
      assert length(events) == 2
      types = Enum.map(events, & &1["type"])
      assert "alpha" in types
      assert "beta" in types
    end
  end
end
