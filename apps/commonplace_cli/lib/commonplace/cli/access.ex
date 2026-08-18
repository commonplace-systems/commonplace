defmodule Commonplace.CLI.Access do
  @moduledoc """
  How the CLI gets at a workspace's commits store: **route, refuse, or
  open locally** — decided BEFORE anything is opened (CX-x8jk).

  ## Why

  2026-08-06: `commonplace bd ready`, run from the workspace directory —
  documented usage — booted the escript's embedded `:commonplace` app,
  resolved its data dir from cwd to the LIVE `workspace/.commonplace`,
  and opened the live commits CubDB beside the running serve. Two
  appenders on one CubDB directory is how the store gets corrupted.

  CX-2479 made that lose instead of corrupt: `CommitStore.init/1` takes a
  non-blocking `flock(2)` on `<data_dir>/commits.lock` and stops with
  `{:commits_store_locked, detail}`. But the user asked a READ question
  and got a crash out of the store layer — a refusal from a component
  that has no idea what was wanted. This module is the tool-layer half:
  the same contract `commonplace_mcp` has had all along (refuse without a
  serve), one binary over.

  ## The decision table

      serve reachable?   commits.lock flock   mode
      ----------------   ------------------   ------------------------
      yes                (not probed)         :route  — talk to the serve
      no                 held                 :refuse — named refusal
      no                 free                 :local  — open it ourselves

  `decide/2` is that table and nothing else: pure, total, unit-tested.
  `resolve/2` supplies its two inputs through injectable connector
  functions so the branch selection is testable without distribution.

  **Local open stays legal** in exactly one case — no serve, no flock —
  which is the genuine offline single-user workspace. That case must keep
  working; most CLI use is against non-live checkouts.

  ## The probe must never become an eviction

  "Is the store locked?" is answered by taking the lock and immediately
  releasing it (`Flock.try_lock/2` + `Flock.unlock/1`). flock(2) is
  per-open-file-description, so a failed acquisition touches nothing the
  holder owns, and `nif_open/2` passes no `O_CREAT`/`O_TRUNC` — a missing
  lock file stays missing and an existing one keeps its bytes. There is
  deliberately no takeover path, no "stale" heuristic, and no read of the
  lock file's CONTENT to decide anything: the file's content is a hint
  for humans, the kernel decides. (The deleted `CLI.acquire_db_lock/1`
  did the opposite of all three.) `cli_access_test.exs` proves the holder
  still excludes a third opener after a probe.

  ## Identifying "the serve FOR THIS data dir"

  Discovery is `<data_dir>/node_name` → connect. That alone only proves
  *a* serve answers, so — as `commonplace_mcp` does for the same reason
  (CX-fml6, an orphan serve from a different workspace) — we then RPC the
  remote's own `Application.get_env(:commonplace, :data_dir)` and compare.
  `Application` is always loaded on any live node, so this RPC cannot
  force-load a module into the serve (see CLAUDE.md: an RPC to an
  unloaded module is a write).

  A MISMATCH means that node is not our serve: we disconnect and continue
  as if no serve were reachable, which normally lands on `:refuse`
  because our own dir is locked by whoever really holds it. UNVERIFIABLE
  (rpc failed, nil) is absence of evidence, not evidence of mismatch — an
  older serve build cannot answer — so it warns on stderr and proceeds.
  """

  alias Commonplace.Store.{CommitStore, CommitStoreClient, LockRefusal}
  alias Commonplace.Flock

  @type reach_failure ::
          {:read_node_name, nil}
          | {:node_start, {:error, term()}}
          | {:node_connect, false | :ignored}
          | {:verify_serves_this_dir, {:mismatch, String.t()}}
  @type serve_result :: {:ok, node()} | {:not_running, reach_failure()}
  @type lock_state :: :held | :free | :not_probed
  @type mode :: {:route, node()} | {:refuse, reach_failure()} | :local

  @doc """
  The decision table, pure. `flock_state` is ignored when a serve is
  reachable — routing does not care who holds the lock, that is the
  serve's business and the whole point of routing.
  """
  @spec decide(serve_result(), lock_state()) :: mode()
  def decide({:ok, node}, _flock_state), do: {:route, node}
  def decide({:not_running, failure}, :held), do: {:refuse, failure}
  def decide({:not_running, _failure}, :free), do: :local

  @doc """
  Resolve the access mode for `data_dir`.

  Options (all functions, for tests; every default is the real thing):

    * `:connect` — `(data_dir -> serve_result())`
    * `:probe_lock` — `(data_dir -> :held | :free)`

  The lock is probed only when no serve is reachable: with a serve up we
  do not need to know, and not probing is one fewer touch of a live
  workspace's files.
  """
  @spec resolve(String.t(), keyword()) :: mode()
  def resolve(data_dir, opts \\ []) do
    connect = Keyword.get(opts, :connect, &connect_to_serve/1)
    probe = Keyword.get(opts, :probe_lock, &probe_lock/1)

    case connect.(data_dir) do
      {:ok, node} -> decide({:ok, node}, :not_probed)
      {:not_running, _failure} = unavailable -> decide(unavailable, probe.(data_dir))
    end
  end

  @doc """
  Resolve and act: point the store client at the serve, open locally, or
  print the refusal and halt.

  Extra options beyond `resolve/2`'s, again for tests:

    * `:on_route` — `(node -> any)`, default `set_remote_node/1`
    * `:on_local` — `(data_dir -> any)`, default boot the local app
    * `:on_refuse` — `(data_dir, reach_failure -> any)`, default print +
      `System.halt(1)`
  """
  @spec ensure_started(String.t(), keyword()) :: :ok | any()
  def ensure_started(data_dir, opts \\ []) do
    on_route = Keyword.get(opts, :on_route, &route/1)
    on_local = Keyword.get(opts, :on_local, &start_local/1)
    on_refuse = Keyword.get(opts, :on_refuse, &refuse/2)

    if already_attached?(data_dir) do
      :ok
    else
      case resolve(data_dir, opts) do
        {:route, node} -> on_route.(node)
        :local -> on_local.(data_dir)
        {:refuse, failure} -> on_refuse.(data_dir, failure)
      end
    end
  end

  # Re-entrancy. One CLI invocation can call ensure_started/1 more than
  # once (and the test suite calls it many times in one BEAM). If THIS VM
  # is already the local holder, probing would find our own flock held —
  # flock conflicts across open file descriptions even within a single
  # process — and we would refuse against ourselves. Likewise once
  # routing is configured there is nothing left to decide.
  defp already_attached?(data_dir) do
    case CommitStoreClient.remote_node() do
      {:ok, _node} ->
        true

      :local ->
        is_pid(Process.whereis(CommitStore)) and
          same_dir?(Application.get_env(:commonplace, :data_dir), data_dir)
    end
  end

  defp same_dir?(a, b) when is_binary(a) and is_binary(b), do: Path.expand(a) == Path.expand(b)
  defp same_dir?(_, _), do: false

  @doc """
  Non-destructive answer to "does a live process hold this store?".

  `:enoent` — no lock file — means no CommitStore has ever opened this
  data dir, i.e. free. Any other error is reported free too: we do not
  have positive evidence of a holder, and the local open we fall through
  to fails CLOSED on the real flock anyway. Erring the other way would
  turn an unreadable lock file into a denial of the offline case.
  """
  @spec probe_lock(String.t()) :: :held | :free
  def probe_lock(data_dir) do
    path = CommitStore.commits_lock_path(data_dir)

    case try_probe_lock(path) do
      {:ok, ref} ->
        Flock.unlock(ref)
        :free

      {:error, :would_block} ->
        :held

      {:error, _other} ->
        :free
    end
  end

  # Loading a NIF-backed module whose on_load callback failed makes the
  # module unavailable. Check that condition explicitly so the courtesy
  # probe never manufactures an UndefinedFunctionError; the authoritative
  # local open below will return CommitStore's named fail-closed refusal.
  defp try_probe_lock(path) do
    case Code.ensure_loaded(Flock) do
      {:module, Flock} -> Flock.try_lock(path, :exclusive)
      {:error, _reason} -> {:error, :flock_unavailable}
    end
  rescue
    _error -> {:error, :flock_unavailable}
  end

  @doc """
  Find and connect to the `commonplace serve` node that serves
  `data_dir`. Returns `{:ok, node}` only when the node answers AND does
  not positively contradict our data dir.
  """
  @spec connect_to_serve(String.t(), keyword()) :: serve_result()
  def connect_to_serve(data_dir, opts \\ []) do
    read_name = Keyword.get(opts, :read_node_name, &read_node_name/1)
    start_node = Keyword.get(opts, :start_node, &Node.start(&1, :shortnames))

    case read_name.(data_dir) do
      nil ->
        {:not_running, {:read_node_name, nil}}

      serve_node ->
        # CX-y6uc: disable :global's overlapping-partition protection
        # (default-on since OTP 25). Each CLI invocation is short-lived;
        # without this, repeated CLI calls trip serve's :global into
        # disconnecting them. Must be set before Node.start.
        :application.set_env(:kernel, :prevent_overlapping_partitions, false)

        cli_name = :"commonplace_cli_#{:rand.uniform(999_999)}"

        case start_node.(cli_name) do
          {:ok, _} -> attach(serve_node, data_dir, opts)
          # Already distributed (e.g. `commonplace serve` started its own
          # named node before calling us) or epmd unavailable.
          {:error, _reason} = error -> {:not_running, {:node_start, error}}
        end
    end
  end

  defp attach(serve_node, data_dir, opts) do
    connect_node = Keyword.get(opts, :connect_node, &Node.connect/1)
    verify_dir = Keyword.get(opts, :verify_dir, &verify_serves_this_dir/2)
    stop_node = Keyword.get(opts, :stop_node, &Node.stop/0)

    # Node.connect/1 returns true | false | :ignored (this node not alive).
    case connect_node.(serve_node) do
      true ->
        case verify_dir.(serve_node, data_dir) do
          :ok ->
            {:ok, serve_node}

          {:mismatch, remote_dir} = mismatch ->
            IO.puts(:stderr, """
            commonplace: #{inspect(serve_node)} (from #{Path.join(data_dir, "node_name")}) \
            serves a DIFFERENT workspace — its data dir is #{inspect(remote_dir)}, not \
            #{inspect(data_dir)}. Ignoring it; that node_name file probably points at an \
            orphan serve.\
            """)

            stop_node.()
            {:not_running, {:verify_serves_this_dir, mismatch}}
        end

      result when result in [false, :ignored] ->
        stop_node.()
        {:not_running, {:node_connect, result}}
    end
  end

  defp read_node_name(data_dir) do
    case File.read(Path.join(data_dir, "node_name")) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          name -> String.to_atom(name)
        end

      {:error, _} ->
        nil
    end
  end

  # See the moduledoc: mismatch is evidence, unverifiable is not.
  defp verify_serves_this_dir(serve_node, data_dir) do
    remote =
      try do
        :rpc.call(serve_node, Application, :get_env, [:commonplace, :data_dir], 5_000)
      catch
        kind, reason -> {:rpc_exception, {kind, reason}}
      end

    case remote do
      dir when is_binary(dir) ->
        if Path.expand(dir) == Path.expand(data_dir), do: :ok, else: {:mismatch, dir}

      other ->
        IO.puts(
          :stderr,
          "commonplace: could not verify that #{inspect(serve_node)} serves #{data_dir} " <>
            "(#{inspect(other)}); proceeding anyway."
        )

        :ok
    end
  end

  # -- default effects --

  defp route(node) do
    CommitStoreClient.set_remote_node(node)
    :ok
  end

  defp refuse(data_dir, failure) do
    IO.puts(
      :stderr,
      LockRefusal.cli_refusal(data_dir, CommitStore.commits_lock_path(data_dir), failure)
    )

    System.halt(1)
  end

  defp start_local(data_dir) do
    # Stop if already running with wrong data_dir (escript auto-start)
    if Application.get_env(:commonplace, :data_dir) != data_dir do
      Application.stop(:commonplace)
    end

    # The escript wrapper no longer preloads :commonplace. Persist this
    # override so loading the embedded commonplace.app cannot replace the
    # deliberately selected workspace with its compile-time "data" default.
    Application.put_env(:commonplace, :data_dir, data_dir, persistent: true)

    case Application.ensure_all_started(:commonplace) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # CX-qida: most commonly the workspace single-owner flock
        # (Commonplace.Workspace.Lock) refusing to start because another
        # process already holds <data_dir>/serve.lock — surface that as a
        # clear, fail-fast CLI error instead of a raw MatchError crash.
        # Workspace.Lock's own init/1 already printed the detailed
        # lock/holder message to stderr; this is the summary.
        IO.puts(:stderr, "Cannot start commonplace: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
