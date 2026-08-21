defmodule Commonplace.DeployGapMonitor do
  @moduledoc """
  Periodically makes a serve-side deploy gap visible in the serve log.

  A Phoenix-as-serve node runs with interactive code loading and does not
  compile after it starts. Its process start is therefore the correct
  reference: a beam newer than that start is code this serve was not built
  with, and lazily loading it would be an unplanned partial deploy.

  `bin/cp-deploy-gap` owns the measurement and names every newer beam. This
  process only supplies the missing push behaviour: successful empty checks
  are silent, while a non-empty result is surfaced without an operator having
  to remember to invoke the gauge.

  This is an alarm, not a deployment policy. It neither restarts the serve nor
  prevents the runtime from loading a newer beam.

  ## ⛔ LOG ON STATE CHANGE, NOT EVERY TICK — the ledger, not the alarm

  The original design logged the gap on EVERY 60s tick while it existed. On the
  live serve that produced **8,332 identical `DEPLOY GAP DETECTED` lines from a
  SINGLE true 6-day gap** — 90% of every error line the serve had ever written,
  the noise the audit-blindness signals (605 unheard canary alarms, 339 persist
  failures) were buried in. A correct detector, behaving as designed, destroyed
  the readability of the sink three owed items depend on. Measured 2026-08-21;
  it is the alarm-vs-ledger defect priced at **8,332-to-1**.

  So a persistent condition is held as ONE OPEN ROW, not re-emitted every tick:

    * **Transitions are logged** — a gap OPENING, CHANGING (the beam set moved),
      or CLEARING, and the gauge FAILING or RECOVERING. Each is one line, at the
      moment it happens, carrying how long the prior condition stood.
    * **A persistent condition heartbeats at a LOW cadence** (default every
      #{60} ticks ≈ hourly) carrying its AGE — visible-not-silent, "louder with
      age", without the per-minute flood. `heartbeat_every` is configurable.
    * **The open condition is QUERYABLE** via `current_condition/0` — the row
      itself: what is open, since when, and for how many ticks. This is the
      ledger proper; the log carries its edges, the state carries its presence.

  ## ⛔ SILENCE STILL PROVES NOTHING — "empty gap" and "monitor dead" coincide

  An empty gap is deliberately silent, so the ABSENCE of a log line is not
  evidence of health. That cost is paid by:

    * **one `:info` line at boot**, naming the resolved gauge path and interval.
      Its absence distinguishes *never started* from *started and quiet*.
    * ⭐ **the touch test is the ONLY liveness check.** To answer "is the monitor
      working?", perturb one beam's mtime and wait one interval; restore it and
      verify by md5. Reading the log cannot answer it.

  Measured 2026-08-14: a serve launched without `--sname commonplace_dev` could
  not be identified by `cp-deploy-gap`; this monitor logged `gap is unknown
  (gauge exit 2)` and, crucially, did NOT report 0 — a serve nobody could
  measure must not read as a serve with nothing pending.
  """

  use GenServer

  require Logger

  @default_interval_ms 60_000
  # Ticks between heartbeats for a persistent non-quiet condition. At the
  # 60s default interval this is ~hourly: a 6-day gap becomes ~144 aging lines,
  # not 8,332 identical ones. The transitions (open/change/clear) are always
  # logged the moment they happen regardless of this.
  @default_heartbeat_every 60

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The current open condition as a queryable row (the ledger proper): a map of
  `:condition` (`:quiet | {:gap, _} | {:error, _, _}`), `:ticks` (how many
  checks it has stood), and `:age_ms` (wall time since it first appeared, nil
  while quiet). Answers "what is open right now" without scanning the log.
  """
  @spec current_condition(GenServer.server()) :: map()
  def current_condition(server \\ __MODULE__) do
    GenServer.call(server, :current_condition)
  end

  @doc false
  def check(opts \\ []) do
    command = Keyword.get(opts, :command, default_command())
    args = Keyword.get(opts, :args, ["--assert-empty"])
    command_opts = Keyword.get(opts, :command_opts, default_command_opts(command))

    try do
      case System.cmd(command, args, command_opts) do
        {_output, 0} ->
          :quiet

        {output, 1} ->
          {:gap, output}

        {output, status} ->
          {:error, status, output}
      end
    rescue
      error in ErlangError -> {:error, :exec, Exception.message(error)}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      heartbeat_every: Keyword.get(opts, :heartbeat_every, @default_heartbeat_every),
      check_opts: Keyword.take(opts, [:command, :args, :command_opts]),
      # Ledger row: the current condition and how long it has stood.
      last: :unset,
      since_ms: nil,
      ticks: 0,
      ticks_since_heartbeat: 0
    }

    # The one line this process logs when nothing is wrong — so "started and
    # quiet" is distinguishable from "never started", and a wrong gauge path is
    # visible at boot rather than at the first check.
    Logger.info(
      "DeployGapMonitor armed — gauge #{inspect(Keyword.get(state.check_opts, :command, default_command()))}, " <>
        "every #{state.interval_ms}ms, heartbeat every #{state.heartbeat_every} ticks. " <>
        "Silence means an EMPTY gap; absence of this line means NOT RUNNING."
    )

    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    {actions, state} = decide(check(state.check_opts), now_ms(), state)
    Enum.each(actions, &emit/1)
    Process.send_after(self(), :check, state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:current_condition, _from, state) do
    age_ms = if state.since_ms, do: now_ms() - state.since_ms, else: nil
    row = %{condition: state.last, ticks: state.ticks, age_ms: age_ms}
    {:reply, row, state}
  end

  @doc """
  Pure state-transition core: given the latest check `result`, the current
  monotonic time `now`, and the ledger `state`, return `{actions, new_state}`.
  Actions are log directives; NO tick re-emits an unchanged condition. Public
  and pure so the log-on-change / heartbeat / clear behaviour is tested without
  a GenServer or `System.cmd`.
  """
  @spec decide(term(), integer(), map()) :: {[tuple()], map()}
  def decide(result, now, %{last: last} = state) do
    cond do
      result == last and result == :quiet ->
        # Empty gap, unchanged — stay silent (the deliberate silence).
        {[], %{state | ticks: state.ticks + 1}}

      result == last ->
        # Persistent non-quiet condition — one open row; heartbeat at low
        # cadence carrying its age, never every tick.
        tsh = state.ticks_since_heartbeat + 1
        ticks = state.ticks + 1

        if tsh >= state.heartbeat_every do
          {[{:heartbeat, result, now - state.since_ms, ticks}],
           %{state | ticks: ticks, ticks_since_heartbeat: 0}}
        else
          {[], %{state | ticks: ticks, ticks_since_heartbeat: tsh}}
        end

      true ->
        # Transition. The prior non-quiet condition (if any) ENDED; the new
        # non-quiet condition (if any) OPENED or CHANGED.
        ended =
          if last not in [:quiet, :unset],
            do: [{:ended, last, now - state.since_ms, state.ticks}],
            else: []

        opened =
          if result != :quiet,
            do: [{:condition, result, if(last in [:quiet, :unset], do: :opened, else: :changed)}],
            else: []

        {ended ++ opened,
         %{state | last: result, since_ms: now, ticks: 1, ticks_since_heartbeat: 0}}
    end
  end

  # --- log emission for each action directive ---------------------------------

  @doc false
  def emit({:condition, {:gap, output}, kind}) do
    banner =
      case kind do
        :opened -> "DEPLOY GAP DETECTED"
        :changed -> "DEPLOY GAP CHANGED"
      end

    Logger.error("""
    #{banner} — this serve may lazily load code built after it started.
    #{String.trim_trailing(output)}
    """)
  end

  def emit({:condition, {:error, status, output}, _kind}) do
    Logger.error("""
    DEPLOY GAP MONITOR FAILED — the serve's deploy gap is unknown (gauge exit #{inspect(status)}).
    #{String.trim_trailing(output)}
    """)
  end

  def emit({:heartbeat, {:gap, output}, age_ms, ticks}) do
    Logger.error("""
    DEPLOY GAP STILL OPEN — #{humanize_age(age_ms)} (#{ticks} checks). Unchanged; not re-listing every tick.
    #{summary_line(output)}
    """)
  end

  def emit({:heartbeat, {:error, status, _output}, age_ms, ticks}) do
    Logger.error(
      "DEPLOY GAP MONITOR STILL FAILING (gauge exit #{inspect(status)}) — " <>
        "#{humanize_age(age_ms)} (#{ticks} checks)."
    )
  end

  # CLEARED / RECOVERED are good news, but a resolution must be CO-VISIBLE with
  # the alarm it resolves: the open logs at :error, so a reader filtering at
  # warning+ would see "GAP DETECTED" and never the all-clear, reading a
  # resolved gap as still open. :warning keeps the close visible below :error
  # (not itself an error) — and `current_condition/0` is the queryable truth
  # regardless of which log lines a reader caught.
  def emit({:ended, {:gap, _output}, age_ms, ticks}) do
    Logger.warning(
      "DEPLOY GAP CLEARED — the gap that stood #{humanize_age(age_ms)} (#{ticks} checks) is gone."
    )
  end

  def emit({:ended, {:error, status, _output}, age_ms, ticks}) do
    Logger.warning(
      "DEPLOY GAP MONITOR RECOVERED — the gauge failure (exit #{inspect(status)}) that stood " <>
        "#{humanize_age(age_ms)} (#{ticks} checks) is gone."
    )
  end

  # The first non-blank line of the gauge output — enough to identify the
  # condition in a heartbeat without re-listing every beam each hour.
  defp summary_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find(&String.contains?(&1, "WOULD-DEPLOY-ON-RESTART"))
    |> case do
      nil -> String.trim_trailing(output) |> String.split("\n") |> List.first() || ""
      line -> String.trim(line)
    end
  end

  defp humanize_age(nil), do: "unknown age"

  defp humanize_age(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp humanize_age(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp humanize_age(ms) when ms < 86_400_000, do: "#{Float.round(ms / 3_600_000, 1)}h"
  defp humanize_age(ms), do: "#{Float.round(ms / 86_400_000, 1)}d"

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp default_command do
    Path.expand("bin/cp-deploy-gap")
  end

  defp default_command_opts(command) do
    [cd: Path.dirname(Path.dirname(command)), stderr_to_stdout: true]
  end
end
