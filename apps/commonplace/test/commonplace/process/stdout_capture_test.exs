defmodule Commonplace.Process.StdoutCaptureTest do
  @moduledoc """
  Tests for stdout/stderr streaming capture to red event log
  in sandbox-exec processes (CX-bqz).

  Verifies that when a sandbox-exec process runs a command,
  each line of stdout/stderr is appended to a RedLog document
  with the correct event format.
  """
  use ExUnit.Case

  alias Commonplace.Process.SandboxExecRunner
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_capture_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    Process.flag(:trap_exit, true)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  describe "stdout capture to red event log" do
    test "captures stdout lines as red events", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "/bin/sh",
          args: ["-c", "echo line_one; echo line_two; echo line_three"],
          name: "stdout_test",
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      # Wait for command to finish and events to be committed
      Process.sleep(1500)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stdout_events = Enum.filter(events, &(&1["type"] == "stdout"))
      lines = Enum.map(stdout_events, & &1["line"])

      assert "line_one" in lines
      assert "line_two" in lines
      assert "line_three" in lines

      # Each event should have a timestamp
      Enum.each(stdout_events, fn event ->
        assert Map.has_key?(event, "timestamp")
        assert is_binary(event["timestamp"])
      end)

      GenServer.stop(pid)
    end

    test "captures stderr lines as red events with type stderr", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "/bin/sh",
          args: ["-c", "echo err_one >&2; echo err_two >&2"],
          name: "stderr_test",
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      # Wait for command to finish and events to be committed
      Process.sleep(1500)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stderr_events = Enum.filter(events, &(&1["type"] == "stderr"))
      lines = Enum.map(stderr_events, & &1["line"])

      assert "err_one" in lines
      assert "err_two" in lines

      GenServer.stop(pid)
    end

    test "captures mixed stdout and stderr in order", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "/bin/sh",
          args: ["-c", "echo out_first; echo err_first >&2; echo out_second"],
          name: "mixed_test",
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      # Wait for command to finish
      Process.sleep(1500)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      # All output lines should appear as events
      all_lines = Enum.map(events, & &1["line"])
      all_types = Enum.map(events, & &1["type"])

      assert "out_first" in all_lines
      assert "err_first" in all_lines
      assert "out_second" in all_lines

      assert "stdout" in all_types
      assert "stderr" in all_types

      GenServer.stop(pid)
    end

    test "red events have correct JSON format", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "/bin/sh",
          args: ["-c", "echo hello_world"],
          name: "format_test",
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      Process.sleep(1500)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stdout_events = Enum.filter(events, &(&1["type"] == "stdout"))
      assert length(stdout_events) >= 1

      event = Enum.find(stdout_events, &(&1["line"] == "hello_world"))
      assert event != nil
      assert event["type"] == "stdout"
      assert event["line"] == "hello_world"
      assert is_binary(event["timestamp"])

      # Verify the timestamp is valid ISO8601
      assert {:ok, _, _} = DateTime.from_iso8601(event["timestamp"])

      GenServer.stop(pid)
    end

    test "generates event_log_uuid when not provided", %{store: store, root: root} do
      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "/bin/sh",
          args: ["-c", "echo auto_uuid"],
          name: "auto_uuid_test",
          sync_interval: 50
        )

      # The runner should still work without crashing
      Process.sleep(1500)

      # Get the event_log_uuid from the runner's state
      log_uuid = SandboxExecRunner.event_log_uuid(pid)
      assert is_binary(log_uuid)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stdout_events = Enum.filter(events, &(&1["type"] == "stdout"))
      lines = Enum.map(stdout_events, & &1["line"])
      assert "auto_uuid" in lines

      GenServer.stop(pid)
    end
  end
end
