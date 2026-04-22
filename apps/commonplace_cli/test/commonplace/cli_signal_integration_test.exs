defmodule Commonplace.CLI.SignalIntegrationTest do
  @moduledoc """
  Integration test: CLI signal → magenta → red onramp → persistent log.

  Exercises the full messaging pipeline: send a magenta message via the
  signal command's logic, have an onramp GenServer capture it, commit
  the red log, and verify the event persisted.
  """
  use ExUnit.Case

  alias Commonplace.Dataflow.{Magenta, RedLog}
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_signal_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  test "signal sends magenta message that onramp persists to red log", %{store: store} do
    log_uuid = "log-#{UUID.uuid4()}"
    topic = "test/signal/#{:rand.uniform(1_000_000)}"

    # Start the onramp — subscribes to the magenta topic
    {:ok, onramp_pid} = RedLog.start_onramp(log_uuid, topic, store)

    # Send a magenta message (same as what CLI signal does)
    msg = Magenta.message("deploy", "cli", %{"version" => "2.0", "env" => "prod"})
    Magenta.send(topic, msg)

    # Give onramp time to receive
    Process.sleep(50)

    # Commit the red log
    RedLog.commit_onramp(onramp_pid)
    Process.sleep(50)

    # Load the red log from store and verify
    log = RedLog.load(log_uuid, store)
    events = RedLog.read(log)

    assert length(events) == 1
    event = hd(events)
    assert event["type"] == "deploy"
    assert event["source"] == "cli"
    assert event["payload"]["version"] == "2.0"
    assert event["payload"]["env"] == "prod"
    assert is_binary(event["timestamp"])
  end

  test "multiple signals accumulate in the red log", %{store: store} do
    log_uuid = "log-#{UUID.uuid4()}"
    topic = "test/multi/#{:rand.uniform(1_000_000)}"

    {:ok, onramp_pid} = RedLog.start_onramp(log_uuid, topic, store)

    # Send several messages
    Magenta.send(topic, Magenta.message("start", "orchestrator", %{"process" => "alpha"}))
    Magenta.send(topic, Magenta.message("health_check", "monitor", %{"status" => "ok"}))
    Magenta.send(topic, Magenta.message("stop", "cli", %{"reason" => "maintenance"}))

    Process.sleep(50)
    RedLog.commit_onramp(onramp_pid)
    Process.sleep(50)

    log = RedLog.load(log_uuid, store)
    events = RedLog.read(log)

    assert length(events) == 3
    types = Enum.map(events, & &1["type"])
    assert types == ["start", "health_check", "stop"]
  end

  test "red log survives across onramp restarts", %{store: store} do
    log_uuid = "log-#{UUID.uuid4()}"
    topic = "test/restart/#{:rand.uniform(1_000_000)}"

    # First onramp session
    {:ok, pid1} = RedLog.start_onramp(log_uuid, topic, store)
    Magenta.send(topic, Magenta.message("event-1", "a", %{}))
    Process.sleep(50)
    RedLog.commit_onramp(pid1)
    Process.sleep(50)
    GenServer.stop(pid1)

    # Second onramp session — should pick up existing log
    {:ok, pid2} = RedLog.start_onramp(log_uuid, topic, store)
    Magenta.send(topic, Magenta.message("event-2", "b", %{}))
    Process.sleep(50)
    RedLog.commit_onramp(pid2)
    Process.sleep(50)

    log = RedLog.load(log_uuid, store)
    events = RedLog.read(log)

    assert length(events) == 2
    types = Enum.map(events, & &1["type"])
    assert types == ["event-1", "event-2"]
  end

  test "signal with JSON payload is preserved end-to-end", %{store: store} do
    log_uuid = "log-#{UUID.uuid4()}"
    topic = "test/json/#{:rand.uniform(1_000_000)}"

    {:ok, onramp_pid} = RedLog.start_onramp(log_uuid, topic, store)

    # Simulate what CLI signal does with a JSON payload argument
    payload_json = ~s({"key": "value", "count": 42, "nested": {"a": true}})
    {:ok, payload} = Jason.decode(payload_json)
    msg = Magenta.message("config_update", "cli", payload)
    Magenta.send(topic, msg)

    Process.sleep(50)
    RedLog.commit_onramp(onramp_pid)
    Process.sleep(50)

    log = RedLog.load(log_uuid, store)
    events = RedLog.read(log)

    assert length(events) == 1
    event = hd(events)
    assert event["payload"]["key"] == "value"
    assert event["payload"]["count"] == 42
    assert event["payload"]["nested"]["a"] == true
  end
end
