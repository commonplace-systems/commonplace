defmodule Commonplace.ApplicationWorkspaceLockGatingTest do
  @moduledoc """
  CX-qida: the workspace single-owner flock is DOUBLE opt-in like
  `:orchestrator_on_boot` / `:bursar_on_boot` — explicit config
  (`:workspace_lock_on_boot`, default false). Bare `mix test`, library
  embedding, and one-shot CLI commands never set the flag and never take
  the lock; only `commonplace serve` and the Phoenix-as-serve Mode B boot
  path opt in (see `Commonplace.CLI.Serve.run/3` and config/runtime.exs).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Workspace.Lock

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_workspace_lock_gate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.delete_env(:commonplace, :workspace_lock_on_boot)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "flag absent → no child (default off)", %{dir: dir} do
    assert Commonplace.Application.workspace_lock_children(dir) == []
  end

  test "flag false → no child", %{dir: dir} do
    Application.put_env(:commonplace, :workspace_lock_on_boot, false)
    assert Commonplace.Application.workspace_lock_children(dir) == []
  end

  test "flag true → named permanent child spec, no workspace root required", %{dir: dir} do
    # Unlike orchestrator_children/0 and bursar_children/0, this gate does
    # NOT also require a resolvable workspace root — the corruption it
    # guards against (two CubDB writers on one data_dir) predates a root
    # file existing (e.g. mid `commonplace init`).
    refute File.exists?(Path.join(dir, "root"))
    Application.put_env(:commonplace, :workspace_lock_on_boot, true)

    assert [spec] = Commonplace.Application.workspace_lock_children(dir)
    assert spec == {Lock, data_dir: dir}
  end

  test "mix test boot takes no lock: default env leaves serve.lock absent", %{dir: dir} do
    # Mirrors the real `mix test` / library-embedding path: nothing sets
    # :workspace_lock_on_boot, so Commonplace.Application never adds the
    # locker child, and the lock file is never created.
    assert Commonplace.Application.workspace_lock_children(dir) == []
    refute File.exists?(Lock.lock_path(dir))
  end
end
