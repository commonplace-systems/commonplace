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
