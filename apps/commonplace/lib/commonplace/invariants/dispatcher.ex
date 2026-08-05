defmodule Commonplace.Invariants.Dispatcher do
  @moduledoc """
  The alarm path of the resting-state invariant layer: the process that
  turns head advances into validation runs. Step 2 of the 2026-08-05
  design (`docs/plans/2026-08-05-resting-state-invariants-design.md`,
  §4.2 "one validator engine, bound to the choke, not the doors"; §7 R1,
  R2, R9).

  ## What binds it to the store

  `Commonplace.Store.CommitStore.put_latest/5` — the single function
  through which `{:latest, uuid}` ever moves — casts `{:advance, meta}`
  here after the pointer lands. That is one function call and one cast
  added to the synchronous write path, and nothing else: everything
  below happens in this process and in tasks it starts.

  Dispatch is FROM THE CHOKE, never inferred from a subscription (§7
  R2). The `"commits:*"` / `"blue:*"` PubSub topics look like they would
  serve — they do not: a subscriber misses every advance that happens
  while it is down or restarting, and misses the ones no broadcast
  covers, so a validator built on them would report green about windows
  it never saw. The funnel cannot miss an advance, because an advance IS
  a call to the funnel.

  ## R9, the locked pin — async is a property of ALARM only

  Per §7 R9: **the async detection window is a property of alarm only;
  block-promotion (imports only, R4) must be synchronous in-choke or not
  run at all — async-block would be divergence-by-timing.** Nothing in
  this module refuses, blocks, or repairs anything; it is alarm and only
  alarm (§7 R4: local merges are never blocked; §4.3: observe before
  refuse). When block-promotion is built (step 4), it does NOT arrive by
  making this dispatcher stricter — a refusal decided here, after the
  head has already moved, would refuse on one node and not on another
  purely by scheduling. It belongs inside the choke, synchronously,
  before the `put_multi`.

  ## Coalescing, and what the backstop is for

  Advances arrive at write rate; validation is a full recompute over the
  corpus (§1(c): full recompute, instance-first). So advances are
  accumulated and debounced (`:debounce_ms`), and consecutive runs are
  spaced by `:min_interval_ms`. Both mean this dispatcher deliberately
  does NOT validate every intermediate state — it validates the state at
  rest, which is what a resting-state invariant is about.

  It also means a violation that exists only between two advances inside
  one debounce window can go unreported here. That is the standing black
  audit's job (`bin/bd-invariants`, `Commonplace.Bd.Invariants.check_all/2`)
  — the continuous backstop this dispatcher does not replace. Treat a
  green dispatcher as "nothing at rest was violating", never as "no
  violation ever existed".

  ## Failure posture

  A validation task that crashes is logged and recorded in `status/0`;
  it never takes down this process, and this process is never in the
  write path's way. If the workspace root cannot be resolved (no
  workspace — tests, fresh installs, one-shot CLI), the run is skipped
  and `status/0` says so, rather than silently reporting a green run
  over nothing.
  """

  use GenServer

  require Logger

  alias Commonplace.Invariants.{Engine, Mode, Registry}

  @default_debounce_ms 2_000
  @default_min_interval_ms 60_000
  @max_pending_uuids 256

  @doc """
  Starts the dispatcher.

  Options (all defaulted from app env / constants, all overridable so
  tests can inject a fake engine, a fake context, and short timers):

    * `:name` — registered name (default `__MODULE__`).
    * `:enabled` — default `Application.get_env(:commonplace,
      :invariant_dispatch_enabled, true)`. When false, advances are
      counted as dropped and nothing runs.
    * `:debounce_ms`, `:min_interval_ms`.
    * `:context_fn` — arity-0, returns `{:ok, context}` or
      `{:skip, reason}`. Default resolves the workspace root and the
      `CommitStoreClient` into the shape `Engine.run/2` expects.
    * `:engine` — module exposing `run/2` (default `Engine`).
    * `:task_supervisor` — where validation tasks run (default
      `Commonplace.Invariants.TaskSupervisor`).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ops visibility: whether dispatch is on, how much is queued, when the
  last run started and how it ended, and how many advances were dropped
  because dispatch was disabled.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get(opts, :enabled, Application.get_env(:commonplace, :invariant_dispatch_enabled, true)),
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      min_interval_ms: Keyword.get(opts, :min_interval_ms, @default_min_interval_ms),
      context_fn: Keyword.get(opts, :context_fn, &default_context/0),
      engine: Keyword.get(opts, :engine, Engine),
      task_supervisor: Keyword.get(opts, :task_supervisor, Commonplace.Invariants.TaskSupervisor),
      pending: MapSet.new(),
      pending_count: 0,
      timer: nil,
      task: nil,
      last_run_started_at: nil,
      last_run_result: nil,
      runs: 0,
      dropped: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:advance, _meta}, %{enabled: false} = state) do
    {:noreply, %{state | dropped: state.dropped + 1}}
  end

  def handle_cast({:advance, meta}, state) do
    # `pending` is bounded on purpose: under churn the distinct-uuid set
    # is unbounded, and this process must not grow with write volume.
    # Past the cap the COUNT still rises — the uuids are a diagnostic,
    # the count is the trigger, and losing the former must not lose the
    # latter.
    pending =
      if MapSet.size(state.pending) < @max_pending_uuids do
        MapSet.put(state.pending, Map.get(meta, :doc_uuid))
      else
        state.pending
      end

    state = %{state | pending: pending, pending_count: state.pending_count + 1}

    {:noreply, arm(state)}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       pending_count: state.pending_count,
       last_run_started_at: state.last_run_started_at,
       last_run_result: state.last_run_result,
       runs: state.runs,
       dropped: state.dropped
     }, state}
  end

  @impl true
  def handle_info(:debounce_fired, state) do
    state = %{state | timer: nil}

    cond do
      state.pending_count == 0 ->
        {:noreply, state}

      state.task != nil ->
        {:noreply, state}

      true ->
        case remaining_interval(state) do
          0 -> {:noreply, start_run(state)}
          ms -> {:noreply, arm(state, ms)}
        end
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil, last_run_result: result}

    {:noreply, if(state.pending_count > 0, do: arm(state), else: state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning(
      "Commonplace.Invariants.Dispatcher: validation task exited: #{inspect(reason)}"
    )

    state = %{state | task: nil, last_run_result: {:error, reason}}

    {:noreply, if(state.pending_count > 0, do: arm(state), else: state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp arm(state, ms \\ nil)
  defp arm(%{timer: timer} = state, _ms) when timer != nil, do: state

  defp arm(state, ms) do
    %{state | timer: Process.send_after(self(), :debounce_fired, ms || state.debounce_ms)}
  end

  defp remaining_interval(%{last_run_started_at: nil}), do: 0

  defp remaining_interval(state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_run_started_at
    max(state.min_interval_ms - elapsed, 0)
  end

  defp start_run(state) do
    subjects = MapSet.to_list(state.pending)
    engine = state.engine
    context_fn = state.context_fn

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        run_validation(engine, context_fn, subjects)
      end)

    %{
      state
      | pending: MapSet.new(),
        pending_count: 0,
        task: task,
        runs: state.runs + 1,
        last_run_started_at: System.monotonic_time(:millisecond)
    }
  end

  # Runs in the TASK, never in this GenServer — R2's whole point is that
  # nothing about validation serializes behind the store's mailbox, and
  # nothing about it serializes behind this mailbox either.
  defp run_validation(engine, context_fn, subjects) do
    case safe_context(context_fn) do
      {:ok, context} ->
        started = System.monotonic_time(:millisecond)
        mode = Mode.mode()

        {violations, errors} =
          Registry.all()
          |> Enum.map(& &1.scope.domain)
          |> Enum.uniq()
          |> Enum.reduce({0, 0}, fn domain, {violations, errors} ->
            %{results: results} = engine.run(context, domain: domain)

            Enum.reduce(results, {violations, errors}, fn {name, result}, {v, e} ->
              Enum.each(result.violations, &alarm(:violation, name, &1, mode))
              Enum.each(result.errors, &alarm(:error, name, &1, mode))
              {v + length(result.violations), e + length(result.errors)}
            end)
          end)

        duration = System.monotonic_time(:millisecond) - started

        :telemetry.execute(
          [:commonplace, :invariants, :run],
          %{violations: violations, errors: errors, duration_ms: duration},
          %{mode: mode, advanced_docs: length(subjects)}
        )

        :ok

      {:skip, reason} ->
        {:skipped, reason}
    end
  end

  defp safe_context(context_fn) do
    context_fn.()
  rescue
    e -> {:skip, {:context_raised, Exception.message(e)}}
  catch
    kind, value -> {:skip, {:context_threw, kind, value}}
  end

  # Never a bare count: a violation is reported with its invariant name,
  # its subject, and its details, everywhere it is reported. A count
  # without shapes is unactionable and gets ignored, which is how an
  # alarm becomes decoration (reference_counts_need_shapes).
  defp alarm(kind, name, detail, mode) do
    subject = Map.get(detail, :subject)
    details = Map.drop(detail, [:subject])

    Logger.warning(
      "Commonplace.Invariants: #{kind} — invariant=#{inspect(name)} " <>
        "subject=#{inspect(subject)} mode=#{inspect(mode)} details=#{inspect(details)}"
    )

    :telemetry.execute(
      [:commonplace, :invariants, :violation],
      %{count: 1},
      %{name: name, subject: subject, details: details, mode: mode, kind: kind}
    )

    Commonplace.Dataflow.PubSub.broadcast_red(
      subject || "workspace",
      {:invariant, :violation, %{name: name, subject: subject, details: details, mode: mode}}
    )
  end

  defp default_context do
    case Commonplace.Workspace.root_uuid() do
      {:ok, root_uuid} when is_binary(root_uuid) ->
        {:ok, %{root_uuid: root_uuid, store: Commonplace.Store.CommitStoreClient}}

      _ ->
        {:skip, :no_workspace_root}
    end
  end
end
