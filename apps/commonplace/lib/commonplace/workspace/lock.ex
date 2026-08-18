defmodule Commonplace.Workspace.Lock do
  @moduledoc """
  Workspace single-owner enforcement (CX-qida).

  Two `commonplace serve` processes (or a `serve` plus a Phoenix-as-serve
  Mode B boot) opening the same `data_dir` can interleave CommitStore
  (CubDB) writes and compaction — CubDB does not lock its own data
  directory, so this is a real corruption risk, not just a "two people
  logged in" annoyance. This GenServer takes an OS advisory `flock(2)`
  exclusive lock on `<data_dir>/serve.lock` at `init/1` and holds it for
  the lifetime of the owning BEAM process.

  ## Crash safety, not stale-lock cleanup

  The lock's file descriptor lives inside this GenServer's NIF resource
  (see `Commonplace.Flock`), which the OS keeps open for as long as
  the resource is reachable. When the VM dies — cleanly or via crash —
  the OS itself closes every fd belonging to the dead process and
  `flock(2)`'s hold releases with it. There is no lock file to clean up
  by hand and no stale-lock state to reconcile; the next owner's
  `flock()` simply succeeds once the old process is well and truly gone.

  ## Why not `Flock.with_exclusive_lock/3`

  `Commonplace.Flock` already ships a scoped helper
  (`with_exclusive_lock/3` / `with_shared_lock/3`), but it is
  deliberately **fail-open**: on timeout or any acquisition error it logs
  a warning and runs the caller's function anyway, unlocked. That's the
  right trade-off for its existing callers (best-effort coordination
  around opportunistic writes). It is the *wrong* trade-off here — two
  workspace owners on one `data_dir` is exactly the corruption scenario
  this module exists to prevent, so acquisition failure must be
  fail-**closed**.

  This module reuses the lower-level primitives instead:
  `Flock.try_lock/2` (which returns `{:error, reason}` rather than
  silently proceeding) and `Flock.unlock/1`. On failure, `init/1` returns
  `{:stop, reason}`, which fails the owning `Supervisor.start_link/2`
  and in turn `Application.start/2` / `Application.ensure_all_started/1`
  — the second serve exits nonzero instead of running unlocked.

  ## Scope: single host only

  `flock(2)` coordinates processes on one host; it does not reach across
  hosts (e.g. two machines with the same workspace directory
  NFS-mounted). That configuration is explicitly unsupported by this
  lock — cluster peers never open the workspace `data_dir` directly in
  the first place. They reach the owning serve node's CommitStore over
  BEAM distribution (`Commonplace.Store.CommitStoreClient`) and its
  green-token lock authority via `Commonplace.Green.BursarClient`, so
  they never contend for this file lock at all.

  ## Boot gating

  Like `:orchestrator_on_boot` / `:bursar_on_boot`
  (`Commonplace.Application`), this child is DOUBLE opt-in: it is only
  added to the supervision tree when `:workspace_lock_on_boot` is `true`
  (default `false`). Bare `mix test`, library embedding, and one-shot CLI
  commands never set this flag, so they never take the lock — only
  `commonplace serve` and the Phoenix-as-serve Mode B boot path
  (`COMMONPLACE_DATA_DIR` + `PHX_SERVER`) opt in.
  """

  use GenServer
  require Logger

  alias Commonplace.Flock

  @lock_file "serve.lock"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The lock file path for a given data_dir."
  def lock_path(data_dir), do: Path.join(data_dir, @lock_file)

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    path = lock_path(data_dir)

    File.mkdir_p!(data_dir)
    File.touch!(path)

    case Flock.try_lock(path, :exclusive) do
      {:ok, ref} ->
        {:ok, %{ref: ref, path: path}}

      {:error, reason} ->
        message = failure_message(path, data_dir, reason)
        Logger.error(message)
        IO.puts(:stderr, message)
        {:stop, {:workspace_already_locked, reason, path}}
    end
  end

  @impl true
  def terminate(_reason, %{ref: ref}) do
    Flock.unlock(ref)
    :ok
  end

  defp failure_message(path, data_dir, reason) do
    "Cannot start: another process already owns this workspace.\n" <>
      "  Lock: #{path}\n" <>
      "  Reason: #{inspect(reason)}\n" <>
      "  #{holder_info(data_dir)}" <>
      "Stop the other serve process first."
  end

  defp holder_info(data_dir) do
    pid_file = Path.join(data_dir, "orchestrator.pid")

    case File.read(pid_file) do
      {:ok, content} ->
        "Best-effort holder (from orchestrator.pid): OS pid #{String.trim(content)}\n"

      {:error, _} ->
        "Holder unknown (no orchestrator.pid present).\n"
    end
  end
end
