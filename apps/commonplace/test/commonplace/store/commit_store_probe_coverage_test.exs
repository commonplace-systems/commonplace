defmodule Commonplace.Store.CommitStoreProbeCoverageTest do
  use ExUnit.Case

  alias Commonplace.Store.CommitStore

  describe "CX-rvbr: probe integrity coverage reporting" do
    test "a completed fixture scan reports its exact entry count and elapsed budget" do
      restore_probe_timeout_on_exit()
      Application.put_env(:commonplace, :corruption_probe_timeout_ms, 5_000)
      previous_log_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_log_level) end)

      {dir, name} = probe_fixture_store!(3)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          pid = start_supervised!({CommitStore, data_dir: dir, name: name}, id: name)
          assert is_pid(pid)
        end)

      assert log =~ "CubDB integrity probe completed: entries_walked=3"
      assert log =~ "budget_ms=5000; coverage complete"
      assert log =~ ~r/elapsed_ms=\d+/
    end

    test "a zero-budget fixture scan deterministically reports a partial lower bound with unknown fraction" do
      restore_probe_timeout_on_exit()
      Application.put_env(:commonplace, :corruption_probe_timeout_ms, 0)

      {dir, name} = probe_fixture_store!(3)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pid = start_supervised!({CommitStore, data_dir: dir, name: name}, id: name)
          assert is_pid(pid)
        end)

      assert log =~ "CubDB integrity probe cut short: entries_walked="
      assert log =~ "budget_ms=0; covered fraction UNKNOWN"
      assert log =~ "this is a LOWER BOUND on work done, not a percentage"
      assert log =~ "treating store as healthy"
      assert log =~ ~r/entries_walked=\d+ elapsed_ms=\d+/

      [_, entries_walked] = Regex.run(~r/entries_walked=(\d+)/, log)
      assert String.to_integer(entries_walked) in 0..3
    end
  end

  defp restore_probe_timeout_on_exit do
    previous = Application.fetch_env(:commonplace, :corruption_probe_timeout_ms)

    on_exit(fn ->
      case previous do
        {:ok, timeout_ms} ->
          Application.put_env(:commonplace, :corruption_probe_timeout_ms, timeout_ms)

        :error ->
          Application.delete_env(:commonplace, :corruption_probe_timeout_ms)
      end
    end)
  end

  defp probe_fixture_store!(entry_count) do
    suffix = :rand.uniform(1_000_000)
    dir = Path.join(System.tmp_dir!(), "cx_rvbr_probe_fixture_#{suffix}")
    name = :"cx_rvbr_probe_store_#{suffix}"
    fixture_id = {name, :fixture_cubdb}
    commits_dir = Path.join(dir, "commits")

    File.mkdir_p!(dir)

    db =
      start_supervised!(
        {CubDB, data_dir: commits_dir, auto_compact: false, auto_file_sync: false},
        id: fixture_id
      )

    for n <- 1..entry_count do
      :ok = CubDB.put(db, {:fixture, n}, "value-#{n}")
    end

    :ok = stop_supervised(fixture_id)
    on_exit(fn -> File.rm_rf!(dir) end)

    {dir, name}
  end
end
