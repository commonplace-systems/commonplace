# Orphan Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure managed processes are reliably cleaned up when the orchestrator dies, by reading pgids from the status file on startup and killing by process group.

**Architecture:** Port.open children are already session leaders (PID == PGID). The orchestrator writes their os_pids to `orchestrator_status.json` every 2s. On startup, `kill_orphans` reads this file and kills each recorded process group (SIGTERM, wait 5s, SIGKILL). On clean shutdown, `terminate/2` does the same escalation pattern.

**Tech Stack:** Elixir, Port, Unix process groups, JSON status file

**Spec:** `docs/plans/2026-03-23-orphan-cleanup-design.md`

**PID reuse:** The spec calls for `/proc/<pid>/cmdline` identity verification. We omit this because: (1) we kill by process *group* (`kill -- -<pgid>`), and pgid reuse requires the original session leader to have fully exited AND a new process to have been assigned the exact same PID AND that process to have called `setsid()` — astronomically unlikely in the seconds between crash and restart; (2) the sandbox dirs are cleaned up anyway, so a false positive on a reused pgid would only send a spurious SIGTERM to an unrelated process group, which is caught by the group not existing.

**Note:** The orchestrator is NOT started under an OTP supervisor — it's started via `Orchestrator.start_link` in serve.ex and stopped via `GenServer.stop(orch, :shutdown, 10_000)`. The 5s SIGTERM grace period in `terminate/2` is safe because the caller allows 10s. If the orchestrator is ever placed under a supervisor, set `shutdown: 10_000` in the child spec.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `apps/commonplace/lib/commonplace/process/orchestrator.ex` | Atomic status file writes, SIGTERM/SIGKILL escalation in `terminate/2` |
| `apps/commonplace_cli/lib/commonplace/cli/serve.ex` | Enhanced `kill_orphans` reads status file, kills managed process groups |
| `apps/commonplace/test/commonplace/process/orchestrator_cleanup_test.exs` | Tests for atomic writes and terminate escalation |
| `apps/commonplace_cli/test/commonplace/cli/serve_cleanup_test.exs` | Tests for kill_orphans reading status file |

---

### Task 1: Atomic Status File Writes

**Files:**
- Modify: `apps/commonplace/lib/commonplace/process/orchestrator.ex:414-436`
- Test: `apps/commonplace/test/commonplace/process/orchestrator_cleanup_test.exs`

- [ ] **Step 1: Write failing test for atomic write**

```elixir
# apps/commonplace/test/commonplace/process/orchestrator_cleanup_test.exs
defmodule Commonplace.Process.OrchestratorCleanupTest do
  use ExUnit.Case

  alias Commonplace.Process.Orchestrator
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cleanup_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_cleanup_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    Application.put_env(:commonplace, :data_dir, dir)
    on_exit(fn ->
      Application.delete_env(:commonplace, :data_dir)
      File.rm_rf!(dir)
    end)
    Process.flag(:trap_exit, true)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  describe "status file" do
    test "write uses atomic rename (no .tmp file left behind)", %{dir: dir, store: store, root: root} do
      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100_000)

      # Trigger a reconcile to write the status file
      send(orch, :reconcile)
      Process.sleep(100)

      status_file = Path.join(dir, "orchestrator_status.json")
      tmp_file = status_file <> ".tmp"

      assert File.exists?(status_file)
      refute File.exists?(tmp_file)

      # Verify it's valid JSON
      {:ok, content} = File.read(status_file)
      assert {:ok, _} = Jason.decode(content)

      GenServer.stop(orch)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/commonplace && mix test test/commonplace/process/orchestrator_cleanup_test.exs --trace
```

Expected: FAIL — current `write_status_file` uses `File.write` not write-then-rename, but it should still create the file. The `.tmp` refutation should pass. We need to verify the actual atomic write is in place.

- [ ] **Step 3: Implement atomic write in write_status_file**

In `apps/commonplace/lib/commonplace/process/orchestrator.ex`, replace the `write_status_file` function:

```elixir
  defp write_status_file(state) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    status_file = Path.join(data_dir, "orchestrator_status.json")
    tmp_file = status_file <> ".tmp"

    status = %{
      "pid" => System.pid(),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "processes" => Map.new(state.processes, fn {name, proc} ->
        {name, %{
          "mode" => to_string(proc.mode),
          "sandbox_dir" => proc.sandbox_dir,
          "os_pid" => get_os_pid(proc),
          "started_at" => DateTime.to_iso8601(proc.started_at),
          "alive" => Process.alive?(proc.pid)
        }}
      end)
    }

    File.write!(tmp_file, Jason.encode!(status, pretty: true))
    File.rename!(tmp_file, status_file)
  rescue
    _ -> :ok
  end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd apps/commonplace && mix test test/commonplace/process/orchestrator_cleanup_test.exs --trace
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/lib/commonplace/process/orchestrator.ex apps/commonplace/test/commonplace/process/orchestrator_cleanup_test.exs
git commit -m "feat: atomic status file writes in orchestrator (CX-btk)"
```

---

### Task 2: SIGTERM/SIGKILL Escalation in terminate/2

**Files:**
- Modify: `apps/commonplace/lib/commonplace/process/orchestrator.ex:93-113`
- Test: `apps/commonplace/test/commonplace/process/orchestrator_cleanup_test.exs`

- [ ] **Step 1: Write failing test for graceful shutdown**

Add to `orchestrator_cleanup_test.exs`:

```elixir
  describe "terminate/2 escalation" do
    test "sends SIGTERM then SIGKILL to managed process groups", %{store: store, root: root} do
      # Create a __processes.json with a long-running sleep command
      proc_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = Commonplace.Document.ContentType.create(doc, :text, "__processes.json")
      content = Jason.encode!(%{
        "sleeper" => %{
          "mode" => "sandbox-exec",
          "command" => "sleep",
          "args" => ["3600"]
        }
      })
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, proc_uuid, update, nil)

      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "__processes.json", proc_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100_000)
      send(orch, :reconcile)
      Process.sleep(500)

      # Get the managed process os_pid
      info = Orchestrator.process_info(orch)
      assert %{"sleeper" => sleeper_info} = info
      os_pid = sleeper_info.os_pid
      assert os_pid != nil

      # Verify sleep is running
      {_, 0} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)

      # Stop orchestrator — should kill the sleep process
      GenServer.stop(orch, :shutdown, 10_000)
      Process.sleep(500)

      # Sleep process should be dead
      {_, exit_code} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)
      assert exit_code != 0
    end
  end
```

- [ ] **Step 2: Run test to verify it passes with current code**

```bash
cd apps/commonplace && mix test test/commonplace/process/orchestrator_cleanup_test.exs --trace
```

The test may already pass since `terminate/2` already sends SIGTERM. This test establishes a baseline.

- [ ] **Step 3: Implement SIGTERM/SIGKILL escalation in terminate/2**

Add a module attribute at the top of the module (after `use GenServer`):

```elixir
  @shutdown_grace_ms 5000
```

Replace `terminate/2` in `orchestrator.ex`:

```elixir
  @impl true
  def terminate(_reason, state) do
    # Collect os_pids first, then kill all process groups
    os_pids =
      state.processes
      |> Enum.map(fn {_name, info} -> get_os_pid(info) end)
      |> Enum.reject(&is_nil/1)

    # SIGTERM all process groups
    Enum.each(os_pids, fn pid ->
      System.cmd("kill", ["-TERM", "--", "-#{pid}"], stderr_to_stdout: true)
    end)

    # Wait for graceful shutdown
    Process.sleep(@shutdown_grace_ms)

    # SIGKILL any survivors
    Enum.each(os_pids, fn pid ->
      System.cmd("kill", ["-9", "--", "-#{pid}"], stderr_to_stdout: true)
    end)

    # Stop BEAM wrappers
    Enum.each(state.processes, fn {_name, info} ->
      try do
        if Process.alive?(info.pid), do: GenServer.stop(info.pid, :shutdown, 2000)
      catch
        :exit, _ -> :ok
      end
    end)

    # Clean up PID and status files
    pid_file = pid_file_path(state)
    File.rm(pid_file)
    remove_status_file()

    :ok
  end
```

**Note:** The orchestrator is started via `Orchestrator.start_link` (not under a supervisor) and stopped with a 10s timeout. The 5s grace period is safe. If placed under a supervisor, set `shutdown: 10_000` in the child spec.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd apps/commonplace && mix test test/commonplace/process/orchestrator_cleanup_test.exs --trace
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/lib/commonplace/process/orchestrator.ex apps/commonplace/test/commonplace/process/orchestrator_cleanup_test.exs
git commit -m "feat: SIGTERM/SIGKILL escalation in orchestrator terminate (CX-btk)"
```

---

### Task 3: Enhanced kill_orphans Reads Status File

**Files:**
- Modify: `apps/commonplace_cli/lib/commonplace/cli/serve.ex:78-117`
- Test: `apps/commonplace_cli/test/commonplace/cli/serve_cleanup_test.exs`

- [ ] **Step 1: Write failing test for status-file-based cleanup**

```elixir
# apps/commonplace_cli/test/commonplace/cli/serve_cleanup_test.exs
defmodule Commonplace.CLI.ServeCleanupTest do
  use ExUnit.Case

  describe "kill_orphans reads status file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_serve_cleanup_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "kills process groups from orchestrator_status.json", %{dir: dir} do
      # Start a sleep process to simulate an orphan
      port = Port.open({:spawn_executable, "/bin/sleep"},
        [:binary, {:args, ["3600"]}])
      {:os_pid, sleep_pid} = Port.info(port, :os_pid)

      # Write a fake status file pointing at this process
      status = %{
        "pid" => "99999",
        "processes" => %{
          "orphan" => %{
            "os_pid" => sleep_pid,
            "mode" => "sandbox_exec",
            "sandbox_dir" => "/tmp/cp_sandbox_fake",
            "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "alive" => true
          }
        }
      }

      status_file = Path.join(dir, "orchestrator_status.json")
      File.write!(status_file, Jason.encode!(status))

      # Run kill_orphans
      Commonplace.CLI.Serve.kill_orphans(dir)

      # Give it time to SIGTERM + SIGKILL
      Process.sleep(6500)

      # Sleep process should be dead
      {_, exit_code} = System.cmd("kill", ["-0", "#{sleep_pid}"], stderr_to_stdout: true)
      assert exit_code != 0

      # Status file should be cleaned up
      refute File.exists?(status_file)
    end

    test "handles missing status file gracefully", %{dir: dir} do
      # Should not crash
      Commonplace.CLI.Serve.kill_orphans(dir)
    end

    test "handles corrupted status file gracefully", %{dir: dir} do
      status_file = Path.join(dir, "orchestrator_status.json")
      File.write!(status_file, "not valid json{{{")

      # Should not crash, should clean up the bad file
      Commonplace.CLI.Serve.kill_orphans(dir)
      refute File.exists?(status_file)
    end

    test "handles status file without orchestrator.pid", %{dir: dir} do
      # Start a sleep process to simulate an orphan
      port = Port.open({:spawn_executable, "/bin/sleep"},
        [:binary, {:args, ["3600"]}])
      {:os_pid, sleep_pid} = Port.info(port, :os_pid)

      # Write status file but NO orchestrator.pid
      status = %{
        "pid" => "99999",
        "processes" => %{
          "orphan" => %{
            "os_pid" => sleep_pid,
            "mode" => "sandbox_exec",
            "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "alive" => true
          }
        }
      }

      status_file = Path.join(dir, "orchestrator_status.json")
      File.write!(status_file, Jason.encode!(status))
      # Intentionally no orchestrator.pid file

      Commonplace.CLI.Serve.kill_orphans(dir)
      Process.sleep(6500)

      {_, exit_code} = System.cmd("kill", ["-0", "#{sleep_pid}"], stderr_to_stdout: true)
      assert exit_code != 0
    end

    test "skips processes with null os_pid", %{dir: dir} do
      status = %{
        "pid" => "99999",
        "processes" => %{
          "starting" => %{
            "os_pid" => nil,
            "mode" => "sandbox_exec",
            "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "alive" => true
          }
        }
      }

      status_file = Path.join(dir, "orchestrator_status.json")
      File.write!(status_file, Jason.encode!(status))

      # Should not crash
      Commonplace.CLI.Serve.kill_orphans(dir)

      # Status file should be cleaned up
      refute File.exists?(status_file)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/commonplace_cli && mix test test/commonplace/cli/serve_cleanup_test.exs --trace
```

Expected: FAIL — `kill_orphans` is currently private and doesn't read the status file.

- [ ] **Step 3: Make kill_orphans public and implement status file reading**

In `apps/commonplace_cli/lib/commonplace/cli/serve.ex`, replace `kill_orphans`:

```elixir
  @doc "Kill orphaned processes from a previous serve instance."
  def kill_orphans(data_dir) do
    kill_orchestrator_orphan(data_dir)
    kill_managed_orphans(data_dir)
    cleanup_sandbox_dirs()
  end

  defp kill_orchestrator_orphan(data_dir) do
    pid_file = Path.join(data_dir, "orchestrator.pid")

    case File.read(pid_file) do
      {:ok, content} ->
        os_pid = String.trim(content)
        kill_process_group(os_pid)
        File.rm(pid_file)

      {:error, _} ->
        :ok
    end
  end

  defp kill_managed_orphans(data_dir) do
    status_file = Path.join(data_dir, "orchestrator_status.json")

    case File.read(status_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"processes" => processes}} when is_map(processes) ->
            processes
            |> Enum.each(fn {name, info} ->
              os_pid = info["os_pid"]
              if os_pid do
                IO.puts("Killing orphaned process: #{name} (PGID #{os_pid})")
                kill_process_group("#{os_pid}")
              end
            end)

          _ ->
            :ok
        end

        File.rm(status_file)

      {:error, _} ->
        :ok
    end
  end

  @shutdown_grace_ms 5000

  defp kill_process_group(pid_str) do
    # Check if any process in the group is alive (use -<pgid> for group check)
    case System.cmd("kill", ["-0", "--", "-#{pid_str}"], stderr_to_stdout: true) do
      {_, 0} ->
        # SIGTERM the process group
        System.cmd("kill", ["-TERM", "--", "-#{pid_str}"], stderr_to_stdout: true)
        Process.sleep(@shutdown_grace_ms)
        # SIGKILL survivors
        System.cmd("kill", ["-9", "--", "-#{pid_str}"], stderr_to_stdout: true)
        Process.sleep(500)

      _ ->
        :ok
    end
  end

  defp cleanup_sandbox_dirs do
    case File.ls("/tmp") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "cp_sandbox_"))
        |> Enum.each(fn dir ->
          path = Path.join("/tmp", dir)
          File.rm_rf(path)
        end)
      _ -> :ok
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd apps/commonplace_cli && mix test test/commonplace/cli/serve_cleanup_test.exs --trace
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace_cli/lib/commonplace/cli/serve.ex apps/commonplace_cli/test/commonplace/cli/serve_cleanup_test.exs
git commit -m "feat: kill_orphans reads status file to find managed process pgids (CX-btk)"
```

---

### Task 4: Rebuild Escript and Manual Verification

**Files:**
- No new files

- [ ] **Step 1: Run full test suite**

```bash
cd /home/jes/commonplace && mix test 2>&1 | tail -20
```

Expected: All tests pass (or pre-existing failures only).

- [ ] **Step 2: Rebuild escript**

```bash
cd apps/commonplace_cli && mix escript.build
```

- [ ] **Step 3: Manual verification — clean startup kills orphans**

```bash
# Start a fake orphan process
sleep 3600 &
ORPHAN_PID=$!

# Write a fake status file
cat > workspace/.commonplace/orchestrator_status.json << EOF
{"pid":"99999","processes":{"fake":{"os_pid":$ORPHAN_PID,"mode":"sandbox_exec","started_at":"2026-03-23T00:00:00Z","alive":true}}}
EOF

# Start serve — should kill the orphan
cd workspace && ../apps/commonplace_cli/commonplace_cli serve &
sleep 3

# Verify orphan is dead
kill -0 $ORPHAN_PID 2>&1 && echo "FAIL: orphan still alive" || echo "PASS: orphan killed"
```

- [ ] **Step 4: Manual verification — clean shutdown kills processes**

```bash
# With serve running from step 3, check processes
cd workspace && ../apps/commonplace_cli/commonplace_cli ps

# Kill serve (Ctrl+C equivalent)
kill $(cat workspace/.commonplace/orchestrator.pid)
sleep 6

# Verify no orphans
pgrep -f cp_sandbox && echo "FAIL: orphans remain" || echo "PASS: clean shutdown"
```

- [ ] **Step 5: Commit any fixes from manual testing**

```bash
git add -A && git commit -m "fix: adjustments from manual orphan cleanup testing (CX-btk)"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Atomic status file writes | orchestrator.ex, orchestrator_cleanup_test.exs |
| 2 | SIGTERM/SIGKILL escalation in terminate/2 | orchestrator.ex, orchestrator_cleanup_test.exs |
| 3 | kill_orphans reads status file | serve.ex, serve_cleanup_test.exs |
| 4 | Rebuild and manual verification | — |
