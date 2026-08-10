defmodule Commonplace.FileRmRfGuardTest do
  use ExUnit.Case, async: false

  alias Commonplace.Test.FileRmRfGuard

  @tag :rm_rf_guard_positive_control
  test "refuses to delete the directory captured by the live CommitStore" do
    # This is the guard's proof-of-life: it runs in every suite run and GREEN
    # means the guard fired AND the directory survived. A guard that silently
    # stopped working turns this test RED.
    dir =
      case captured_dir() do
        {:ok, dir} ->
          dir

        {:error, reason} ->
          flunk("""
          rm_rf guard positive control could not observe a live CommitStore, so the
          guard's only proof-of-life did not run: #{reason}
          """)
      end

    assert File.dir?(dir),
           "captured CommitStore directory does not exist before the control: #{dir}"

    assert_raise ExUnit.AssertionError, fn -> File.rm_rf!(dir) end
    assert File.dir?(dir), "guard raised but the CommitStore directory was deleted anyway: #{dir}"

    assert_raise ExUnit.AssertionError, fn -> File.rm_rf(dir) end
    assert File.dir?(dir), "guard raised but the CommitStore directory was deleted anyway: #{dir}"
  end

  defp captured_dir do
    case Process.whereis(Commonplace.Store.CommitStore) do
      nil ->
        {:error, "Commonplace.Store.CommitStore is not running in this test run"}

      _pid ->
        case FileRmRfGuard.captured_dir!() do
          nil -> {:error, "FileRmRfGuard.captured_dir!/0 returned nil"}
          dir -> {:ok, dir}
        end
    end
  rescue
    error ->
      {:error, "FileRmRfGuard.captured_dir!/0 raised #{Exception.message(error)}"}
  end

  # The shorter path to the same harm. An ancestor-only check lets this through,
  # and CubDB's data lives in these files — deleting the `.cub` file destroys the
  # store exactly as thoroughly as deleting the directory that holds it.
  #
  # ⚠️ Do NOT reintroduce a hardcoded `0.cub` here, however much simpler it reads.
  # CubDB renames its data file on every compaction (`0.cub` → `1.cub` → `C.cub` →
  # …), so `0.cub` only exists on a tree that has never compacted. That made this
  # control pass on a fresh checkout and fail on any worktree with accumulated
  # state — and the general form of that bug is the dangerous part: A CONTROL THAT
  # ONLY HOLDS ON A VIRGIN TREE STOPS EXISTING EXACTLY WHEN THE SYSTEM HAS HISTORY,
  # which is when you need it. The file to point at must be DISCOVERED, never
  # assumed.
  #
  # This is also the control that could least afford to lapse: it is the CHILD
  # direction, the half an ancestor-only check sails straight through, where
  # deleting one file under the store destroys it as thoroughly as deleting the
  # directory. The hardest half to reason about was the half whose control had
  # quietly stopped working.
  @tag :rm_rf_guard_positive_control
  test "refuses to delete a file INSIDE the captured directory" do
    dir =
      case captured_dir() do
        {:ok, dir} -> dir
        {:error, reason} -> flunk("child-path control could not observe a live store: #{reason}")
      end

    entries =
      case File.ls(dir) do
        {:ok, entries} -> entries
        {:error, reason} -> flunk("could not list the captured directory #{dir}: #{inspect(reason)}")
      end

    # Control-for-the-control: if the store has no file here, this test would
    # pass without ever exercising the case. An empty directory is a MISSING
    # precondition, not a pass — fail loudly rather than skip.
    child =
      Enum.find_value(entries, fn entry ->
        path = Path.join(dir, entry)
        if File.regular?(path), do: path
      end) ||
        flunk("expected a CubDB data file inside #{dir}; found: #{inspect(entries)}")

    assert File.exists?(child),
           "discovered #{child} inside #{dir} but it does not exist"

    assert_raise ExUnit.AssertionError, fn -> File.rm_rf!(child) end
    assert File.exists?(child), "guard raised but #{child} was deleted anyway"
  end

  # ⚠️ The fix must not OVER-refuse. A sibling whose name merely starts with the
  # captured path's characters is a different directory and must stay deletable
  # — which is why the comparison is on split path segments, not string prefix.
  test "allows deleting a sibling whose name is a string prefix of the captured dir" do
    dir =
      case captured_dir() do
        {:ok, dir} -> dir
        {:error, reason} -> flunk("prefix control could not observe a live store: #{reason}")
      end

    sibling = dir <> "_unrelated"
    File.mkdir_p!(sibling)

    File.rm_rf!(sibling)

    refute File.exists?(sibling)
    assert File.dir?(dir), "the captured directory must be untouched by this test"
  end

  test "allows a test to delete its own temporary directory" do
    dir = Path.join(System.tmp_dir!(), "file-rm-rf-guard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.rm_rf!(dir)

    refute File.exists?(dir)
  end
end
