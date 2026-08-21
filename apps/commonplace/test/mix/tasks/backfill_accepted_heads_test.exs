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

  # ① is a QUAD (boss #13622): the kill-order knob OOMScoreAdjust, verified
  # BY EFFECT (/proc/self/oom_score_adj, kernel-applied) not by systemctl's
  # echo. verify_oom_adj/2 red-first arms — not-asserted (nil expected),
  # exact match, mismatch, unreadable-but-asserted, unparseable.
  describe "verify_oom_adj/2 (the ① kill-order knob)" do
    test "no expectation → not asserted (logged only), even if unreadable" do
      assert Task.verify_oom_adj("900", nil) == :ok
      assert Task.verify_oom_adj(nil, nil) == :ok
    end

    test "the effective value matching the expected passes" do
      assert Task.verify_oom_adj("900", 900) == :ok
      # /proc emits a trailing newline; trimmed before parse.
      assert Task.verify_oom_adj("900\n", 900) == :ok
    end

    test "a mismatch (flag did not take: inherited 200) fails — not a false green" do
      assert Task.verify_oom_adj("200", 900) == {:error, {:oom_adj_mismatch, 200, 900}}
    end

    test "asserted but unreadable fails: cannot confirm the knob by effect" do
      assert Task.verify_oom_adj(nil, 900) == {:error, :oom_adj_unreadable}
    end

    test "asserted but unparseable fails" do
      assert {:error, {:oom_adj_unparseable, "garbage"}} = Task.verify_oom_adj("garbage", 900)
    end
  end

  # Criterion (b), the non-vacuity gate (commonplace-coder #13593, boss
  # #13630): "the work was done" must not share a report shape with "there
  # was nothing to open". Three arms, red-first: a wrong --data-dir (no
  # store dir), an empty/newly-created store (< min bytes), and a real
  # corpus (>= min). The first two are exactly the vacuous-success that a
  # first §3 run produced off a created-on-open empty store.
  describe "check_non_vacuous/2 (the non-vacuity gate)" do
    setup do
      base = Path.join(System.tmp_dir!(), "cp-vac-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, base: base}
    end

    test "a wrong --data-dir (no commits/ subdir) is refused, not created", %{base: base} do
      # base exists but has no commits/ — mirrors passing .../commits so
      # CommitStore would open .../commits/commits fresh.
      File.mkdir_p!(base)
      assert {:error, {:no_store, store_dir}} = Task.check_non_vacuous(base, 1_000_000)
      assert store_dir == Path.join(base, "commits")
      # ⛔ the gate must NOT have created the dir it refused.
      refute File.dir?(store_dir)
    end

    test "an empty/newly-created store (< min bytes) is refused as vacuous", %{base: base} do
      store_dir = Path.join(base, "commits")
      File.mkdir_p!(store_dir)
      # A fresh CubDB writes a few KB of header; simulate with a tiny file.
      File.write!(Path.join(store_dir, "0.cub"), :binary.copy(<<0>>, 4_096))

      assert {:error, {:vacuous, ^store_dir, 4_096, 1_000_000}} =
               Task.check_non_vacuous(base, 1_000_000)
    end

    test "a real corpus (>= min bytes of .cub) passes with its byte count", %{base: base} do
      store_dir = Path.join(base, "commits")
      File.mkdir_p!(store_dir)
      File.write!(Path.join(store_dir, "0.cub"), :binary.copy(<<0>>, 2_000_000))
      assert {:ok, ^store_dir, 2_000_000} = Task.check_non_vacuous(base, 1_000_000)
    end

    test "the sum spans multiple .cub files (CubDB compaction leaves more than one)", %{
      base: base
    } do
      store_dir = Path.join(base, "commits")
      File.mkdir_p!(store_dir)
      File.write!(Path.join(store_dir, "0.cub"), :binary.copy(<<0>>, 600_000))
      File.write!(Path.join(store_dir, "1.cub"), :binary.copy(<<0>>, 600_000))
      assert {:ok, ^store_dir, 1_200_000} = Task.check_non_vacuous(base, 1_000_000)
    end
  end
end
