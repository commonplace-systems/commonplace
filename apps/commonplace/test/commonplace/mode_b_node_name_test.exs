defmodule Commonplace.ModeBNodeNameTest do
  @moduledoc """
  CX-fml6 (discovery half), Part 1: Mode-B parity with Mode A's
  `<data_dir>/node_name` write. Mode A (`commonplace_cli`'s Serve) writes
  this file after `Node.start` and removes it on shutdown; Mode B
  (Phoenix-as-serve) boots through `Commonplace.Application.start/2`
  instead and previously wrote nothing, leaving MCP escript discovery
  dependent on a stale, three-week-old file that happened to be correct
  only by coincidence (same `--sname` reused every launch). This is the
  same Mode-A/Mode-B parity trap CX-nyvm hit with `bursar_on_boot`.

  `maybe_write_node_name/1` is gated on the SAME signal
  `workspace_lock_children/1` uses (`:workspace_lock_on_boot`) plus
  `Node.alive?/0` — an unnamed node has nothing useful to record.

  Tests below exercise the "gate on AND node alive" branch via
  `do_maybe_write_node_name/4`, which takes `alive?`/`node_name` as
  explicit arguments instead of reading live `Node.alive?/0` /
  `Node.self/0`. This avoids the test process starting real BEAM
  distribution (Node.start/Node.stop), which the CX-fml6 execution
  constraints rule out — a test-started node could collide with a live
  serve running on the same box. `maybe_write_node_name/1` itself is
  only exercised for the branches that don't need distribution up
  (gate off, gate absent) — its live-value plumbing is a thin, one-line
  wrapper around `do_maybe_write_node_name/4`.
  """
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mode_b_node_name_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.delete_env(:commonplace, :workspace_lock_on_boot)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "gate off → no file written", %{dir: dir} do
    Application.put_env(:commonplace, :workspace_lock_on_boot, false)

    assert Commonplace.Application.maybe_write_node_name(dir) == :ok
    refute File.exists?(Path.join(dir, "node_name"))
  end

  test "gate absent (default) → no file written", %{dir: dir} do
    assert Commonplace.Application.maybe_write_node_name(dir) == :ok
    refute File.exists?(Path.join(dir, "node_name"))
  end

  test "gate on but node not alive → no file written", %{dir: dir} do
    assert Commonplace.Application.do_maybe_write_node_name(dir, false, true, :fake@nowhere) ==
             :ok

    refute File.exists?(Path.join(dir, "node_name"))
  end

  test "gate on and node alive → file written containing the node name", %{dir: dir} do
    assert Commonplace.Application.do_maybe_write_node_name(dir, true, true, :fake@nowhere) ==
             :ok

    path = Path.join(dir, "node_name")
    assert File.exists?(path)
    assert File.read!(path) == "fake@nowhere"
  end

  test "gate on, node alive, but neither flag true together → no file (both must hold)", %{
    dir: dir
  } do
    assert Commonplace.Application.do_maybe_write_node_name(dir, true, false, :fake@nowhere) ==
             :ok

    refute File.exists?(Path.join(dir, "node_name"))
  end

  test "write into an unwritable/nonexistent directory does not raise" do
    nonexistent =
      Path.join(
        System.tmp_dir!(),
        "cp_mode_b_node_name_missing_#{:rand.uniform(1_000_000_000)}/nested/deeper"
      )

    refute File.exists?(nonexistent)

    assert Commonplace.Application.do_maybe_write_node_name(
             nonexistent,
             true,
             true,
             :fake@nowhere
           ) == :ok

    refute File.exists?(Path.join(nonexistent, "node_name"))
  end
end
