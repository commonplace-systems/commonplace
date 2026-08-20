defmodule Mix.Tasks.Commonplace.BackfillAcceptedHeadsTest do
  @moduledoc """
  BUILD-1 §3, criterion ①: the ceiling self-check must DISCRIMINATE the
  three systemd states that share one observable after exit. These are the
  measured arms (paravel #13573 / boss #13577) turned into a red-first unit
  test — a `loaded`+finite unit passes, a `not-found` (typo'd or GC'd)
  fails, and an `infinity` (flag didn't take) fails.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Commonplace.BackfillAcceptedHeads, as: Task

  @running "MemoryMax=6442450944\nLoadState=loaded\nActiveState=active\n"
  @gone_or_typo "MemoryMax=infinity\nLoadState=not-found\nActiveState=inactive\n"
  @loaded_no_ceiling "MemoryMax=infinity\nLoadState=loaded\nActiveState=active\n"

  test "parse_triple extracts the three fields" do
    assert Task.parse_triple(@running) == %{
             memory_max: "6442450944",
             load_state: "loaded",
             active_state: "active"
           }
  end

  test "a loaded unit with the expected finite ceiling verifies" do
    assert {:ok, triple} = Task.verify_ceiling(@running, 6_442_450_944)
    assert triple.load_state == "loaded"
  end

  test "a not-found unit (typo'd, or GC'd after exit) fails — not a false green" do
    assert {:error, {:unit_not_loaded, _}} = Task.verify_ceiling(@gone_or_typo, 6_442_450_944)
  end

  test "a loaded unit with MemoryMax=infinity fails: the flag did not take" do
    assert {:error, {:no_ceiling, _}} = Task.verify_ceiling(@loaded_no_ceiling, 6_442_450_944)
  end

  test "a loaded unit with the wrong finite ceiling fails the exact-value assertion" do
    assert {:error, {:wrong_ceiling, _, 9_999}} = Task.verify_ceiling(@running, 9_999)
  end

  test "without an expected value, loaded+finite still passes (ceiling present)" do
    assert {:ok, _} = Task.verify_ceiling(@running, nil)
    assert {:error, {:no_ceiling, _}} = Task.verify_ceiling(@loaded_no_ceiling, nil)
  end
end
