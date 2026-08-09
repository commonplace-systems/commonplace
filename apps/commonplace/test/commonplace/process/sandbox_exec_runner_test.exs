defmodule Commonplace.Process.SandboxExecRunnerTest do
  @moduledoc """
  Direct unit tests for SandboxExecRunner GenServer:
  stdout/stderr capture, event log, accessors, and cleanup.
  """
  use ExUnit.Case

  alias Commonplace.Process.SandboxExecRunner
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Dataflow.RedLog

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_runner_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    Process.flag(:trap_exit, true)

    # Create a minimal root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    on_exit(fn ->
      # CX-exg0 backstop: if a test fails BEFORE its GenServer.stop, the runner
      # (linked to the test, not trapping exits) dies via the link WITHOUT
      # running terminate/2 — so its bash tree leaks. A leaked `__CP_STDERR__`
      # relay bash holds the suite's output pipe open and hangs CI on EOF. Reap
      # any such orphan here. We kill ONLY relays that have reparented to init
      # (ppid == 1) — a live test's relay is still owned by the BEAM, so this is
      # safe under concurrency and never kills an in-flight command. The happy
      # path is already covered by terminate/2's tree-reap; this guards failures.
      reap_orphaned_relays()
      File.rm_rf!(dir)
    end)

    %{store: store_name, root: root_uuid}
  end

  test "missing launch identity returns not_found without minting", %{store: store, root: root} do
    identity_uuid = UUID.uuid4()
    secrets = :"runner_missing_identity_#{:rand.uniform(1_000_000)}"

    start_supervised!(
      {SecretStore,
       data_dir: Path.join(System.tmp_dir!(), "cp_runner_secrets_#{identity_uuid}"), name: secrets}
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :not_found} =
                 SandboxExecRunner.start_link(
                   root_uuid: root,
                   store: store,
                   command: "true",
                   identity_uuid: identity_uuid,
                   secret_store: secrets
                 )
      end)

    assert log =~ "signing identity unavailable: :not_found"
    assert :not_found = SecretStore.get(secrets, "signing_pub:" <> identity_uuid)
  end

  # Kill the tree of any `__CP_STDERR__` relay bash that has reparented to init
  # (ppid 1) — i.e. a leaked orphan whose owning runner died without terminate.
  defp reap_orphaned_relays do
    case System.cmd("pgrep", ["-f", "__CP_STDERR__"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_integer/1)
        |> Enum.filter(&reparented?/1)
        |> Enum.each(&kill_orphan_tree/1)

      _ ->
        :ok
    end
  end

  defp reparented?(pid) do
    case System.cmd("ps", ["-o", "ppid=", "-p", "#{pid}"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) == "1"
      _ -> false
    end
  end

  defp kill_orphan_tree(pid) do
    children =
      case System.cmd("pgrep", ["-P", "#{pid}"], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
        _ -> []
      end

    Enum.each(children, &kill_orphan_tree/1)
    System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
  end

  describe "accessors" do
    test "event_log_uuid returns the log UUID", %{store: store, root: root} do
      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "true",
          sync_interval: 50
        )

      uuid = SandboxExecRunner.event_log_uuid(pid)
      assert is_binary(uuid)
      assert String.length(uuid) == 36

      GenServer.stop(pid)
    end

    test "event_log_uuid uses provided UUID when given", %{store: store, root: root} do
      custom_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "true",
          event_log_uuid: custom_uuid,
          sync_interval: 50
        )

      assert SandboxExecRunner.event_log_uuid(pid) == custom_uuid

      GenServer.stop(pid)
    end

    test "sandbox_dir returns a path", %{store: store, root: root} do
      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "sleep",
          args: ["5"],
          sync_interval: 50
        )

      Process.sleep(300)
      sandbox_dir = SandboxExecRunner.sandbox_dir(pid)
      assert is_binary(sandbox_dir)
      assert File.dir?(sandbox_dir)

      GenServer.stop(pid)
    end

    test "os_pid returns a number after command starts", %{store: store, root: root} do
      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "sleep",
          args: ["5"],
          sync_interval: 50
        )

      Process.sleep(400)
      os_pid = SandboxExecRunner.os_pid(pid)
      assert is_integer(os_pid)

      GenServer.stop(pid)
    end
  end

  describe "stdout/stderr capture" do
    test "captures stdout lines as red events", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "echo",
          args: ["hello from runner"],
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      # Wait for command to finish and events to be committed
      Process.sleep(1500)
      GenServer.stop(pid)

      # Read back the event log
      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stdout_events = Enum.filter(events, &(&1["type"] == "stdout"))
      assert length(stdout_events) >= 1
      assert Enum.any?(stdout_events, &(&1["line"] == "hello from runner"))
    end

    test "captures stderr lines with correct type", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "sh",
          args: ["-c", "echo 'error msg' >&2"],
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      Process.sleep(1500)
      GenServer.stop(pid)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stderr_events = Enum.filter(events, &(&1["type"] == "stderr"))
      assert length(stderr_events) >= 1
      assert Enum.any?(stderr_events, &(&1["line"] == "error msg"))
    end

    test "captures mixed stdout and stderr", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "sh",
          args: ["-c", "echo out1; echo >&2 err1; echo out2"],
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      Process.sleep(1500)
      GenServer.stop(pid)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stdout_lines = events |> Enum.filter(&(&1["type"] == "stdout")) |> Enum.map(& &1["line"])
      stderr_lines = events |> Enum.filter(&(&1["type"] == "stderr")) |> Enum.map(& &1["line"])

      assert "out1" in stdout_lines
      assert "out2" in stdout_lines
      assert "err1" in stderr_lines
    end
  end

  describe "event timestamps" do
    test "events have ISO8601 timestamps", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "echo",
          args: ["timestamped"],
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      Process.sleep(1500)
      GenServer.stop(pid)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      for event <- events do
        assert Map.has_key?(event, "timestamp")
        assert {:ok, _, _} = DateTime.from_iso8601(event["timestamp"])
      end
    end
  end

  describe "environment variables" do
    test "passes env vars to the command", %{store: store, root: root} do
      log_uuid = UUID.uuid4()

      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "sh",
          args: ["-c", "echo $MY_VAR"],
          env: %{"MY_VAR" => "custom_value"},
          event_log_uuid: log_uuid,
          sync_interval: 50
        )

      Process.sleep(1500)
      GenServer.stop(pid)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      stdout_lines = events |> Enum.filter(&(&1["type"] == "stdout")) |> Enum.map(& &1["line"])
      assert "custom_value" in stdout_lines
    end
  end

  describe "orphan reaping (CX-exg0)" do
    test "stopping a runner with a long-running command leaves no orphaned OS descendants",
         %{store: store, root: root} do
      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "sleep",
          args: ["3600"],
          sync_interval: 50
        )

      Process.sleep(600)
      os_pid = SandboxExecRunner.os_pid(pid)
      assert is_integer(os_pid)

      # Collect the full descendant tree (the bash + its pipeline children:
      # the `sleep 3600` user command and the __CP_STDERR__ while-read relay)
      # WHILE it is still alive, so a reparent race can't hide them.
      tree = [os_pid | descendant_pids(os_pid)]
      assert length(tree) >= 2, "expected bash + pipeline children, got #{inspect(tree)}"

      GenServer.stop(pid, :normal, 10_000)
      Process.sleep(600)

      survivors =
        Enum.filter(tree, fn p ->
          match?({_, 0}, System.cmd("kill", ["-0", "#{p}"], stderr_to_stdout: true))
        end)

      assert survivors == [],
             "orphaned OS processes survived runner stop: #{inspect(survivors)} " <>
               "(these hold the test output pipe open and hang the suite)"
    end
  end

  # Recursively collect all descendant OS pids of `os_pid` via `pgrep -P`.
  defp descendant_pids(os_pid) do
    case System.cmd("pgrep", ["-P", "#{os_pid}"], stderr_to_stdout: true) do
      {out, 0} ->
        children =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.to_integer/1)

        children ++ Enum.flat_map(children, &descendant_pids/1)

      _ ->
        []
    end
  end

  describe "terminate cleanup" do
    test "kills OS process on stop", %{store: store, root: root} do
      {:ok, pid} =
        SandboxExecRunner.start_link(
          root_uuid: root,
          store: store,
          command: "sleep",
          args: ["60"],
          sync_interval: 50
        )

      Process.sleep(400)
      os_pid = SandboxExecRunner.os_pid(pid)
      assert is_integer(os_pid)

      # Process should be alive
      {_, 0} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)

      GenServer.stop(pid, :normal, 10_000)
      Process.sleep(500)

      # Process should be dead
      {_, exit_code} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)
      assert exit_code != 0
    end
  end
end
