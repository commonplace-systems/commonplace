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
  # and CubDB's data lives in these files — deleting `0.cub` destroys the store
  # exactly as thoroughly as deleting the directory that holds it.
  @tag :rm_rf_guard_positive_control
  test "refuses to delete a file INSIDE the captured directory" do
    dir =
      case captured_dir() do
        {:ok, dir} -> dir
        {:error, reason} -> flunk("child-path control could not observe a live store: #{reason}")
      end

    # ⚠️ Do NOT hardcode a filename. CubDB names its data file by COMPACTION
    # GENERATION — a freshly created store holds `0.cub`, a store that has
    # compacted holds e.g. `7B.cub`. Hardcoding `0.cub` passed in a fresh
    # worktree and failed on a checkout whose store had compacted.
    child =
      case File.ls(dir) do
        {:ok, [entry | _]} -> Path.join(dir, entry)
        other -> flunk("expected CubDB data inside #{dir}; File.ls returned #{inspect(other)}")
      end

    # Control-for-the-control: without this, an empty store directory would let
    # the test pass without ever exercising the child-path case.
    assert File.exists?(child),
           "expected CubDB data inside #{dir}; found: #{inspect(File.ls(dir))}"

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
