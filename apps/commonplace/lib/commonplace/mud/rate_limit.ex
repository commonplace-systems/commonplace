defmodule Commonplace.MUD.RateLimit do
  @moduledoc """
  CX-nf8p — the pre-widening THROUGHPUT gate. The throughput sibling of
  `Commonplace.MUD.SessionLimit`: where SessionLimit bounds session
  CONCURRENCY (64-total / 8-per-principal), this bounds per-session and
  per-principal command THROUGHPUT (commands/sec). Together they bound
  total serve load — concurrency × per-session-rate — which is what lets
  the MUD open past jes-solo/invited-friends without one principal
  starving the rest.

  ## Where it is consulted (reject-BEFORE-enqueue — the anti-DoS spine)

  `check/2` is called at BOTH command entry points, BEFORE the command
  is handed to the `PlayerSession`:

    * web — `CommonplaceWebWeb.MudLive.handle_event("command", …)`,
      before `PlayerSession.input_sync/2`.
    * bot — `Commonplace.MUD.Bot.send_input/3`, before `input_sync/2`.

  Rejecting at the caller — before the cast/call into the PlayerSession —
  means an over-rate command NEVER enters the session's mailbox. Gating
  inside the PlayerSession would leave the flood already buffered in the
  mailbox: the DoS would merely have moved. Reject-before-enqueue is the
  structural "never-queue" property (design §1/§3).

  ## Algorithm — token bucket, LAZY-refill, two scopes (both must pass)

  A token bucket per scope, stored in a public ETS table so the hot path
  (`check/2`, consulted on EVERY command) is direct ETS reads/writes from
  the calling process — never a GenServer call (which would serialize
  every command through one mailbox: the very bottleneck this avoids).

  Each bucket row is `{key, tokens, last_refill_ms}`. On a check we
  LAZY-refill: `tokens' = min(burst, tokens + elapsed * rate)` computed
  from the elapsed monotonic time since `last_refill_ms` — no per-bucket
  timer, no background refill. (Same monotonic lazy-backfill shape as the
  vein-regen in `Commonplace.MUD.Mint` and the watermark cache.)

  Two scopes, and a command is allowed only if BOTH have a token:

    * **per-SESSION** (`{:session, session_id}`) — stops one session
      flooding.
    * **per-PRINCIPAL** (`{:principal, principal}`) — stops one identity
      opening several sessions, each just under the per-session rate, to
      aggregate a flood. Per-session alone is bypassable by many-sessions;
      the aggregate bucket is defense-in-depth with the session-cap and is
      REQUIRED (design §2/§5.2).

  On ACCEPT we decrement and persist both buckets. On REJECT we consume
  nothing and write nothing — the refill stays monotonic from the stored
  `last_refill_ms`, and skipping the write keeps the *flood* path (the
  abusive one) as cheap as possible.

  ## Drop-then-disconnect — the escalation, never queue

  `check/2` returns `:ok | {:drop, :rate} | {:disconnect, :rate}`:

    * transient over-rate → `{:drop, :rate}` — the caller discards THIS
      command and renders a graceful "too fast, slow down" line. The
      command is discarded, never queued.
    * sustained over-rate → `{:disconnect, :rate}` — a per-session
      consecutive-drop counter crosses `disconnect_after_drops`; the
      caller tears the session down (freeing its SessionLimit slot). A
      session that keeps hammering after being throttled is malfunctioning
      or hostile; disconnecting reclaims the slot for well-behaved users.
      An allowed command resets the counter (consecutive-drops semantics),
      so a slow-but-steady client is never disconnected.

  ## Identity binding, cleanup, fail-safe

    * **Principal key = the SERVER-RESOLVED identity** — the caller passes
      the identity the session was spawned under (web: the authenticated
      presence `identity_uuid`; bot: the server-known bot name), NEVER a
      value taken from the command line. A client-named principal bucket
      would be spoofable per-command (design §4/§5.3).
    * **Cleanup:** callers `watch/1` the session pid at spawn (next to
      `SessionLimit.attach/2`); this monitors it and reaps its session
      bucket + drop-counter on session-down. Principal buckets have no pid
      to monitor, so a periodic idle-sweep TTL-expires any bucket untouched
      for `idle_ttl_ms` — ONE timer total, bounded memory, no leak.
    * **Fail-OPEN-but-ALARM:** any unexpected error in `check/2` (including
      the table not existing during a supervised restart) returns `:ok` and
      emits a `[:commonplace, :mud, :rate_limit, :fail_open]` telemetry
      event. A DoS-defense must not become a self-inflicted DoS; the
      SessionLimit concurrency cap is the standing backstop that bounds
      worst-case load regardless (design §4/§5.5).

  ## Scope: restart-not-durable

  Like SessionLimit, the table is in-memory; a serve restart resets every
  bucket (fine — the same reset SessionLimit slots take). This is an
  availability backstop, not a durable quota.
  """

  use GenServer
  require Logger

  @table __MODULE__.Buckets

  # Defaults (tunable via `config :commonplace, :mud_rate_limit, …`). NOT
  # load-bearing: a human types << 5 cmd/s, a bot rarely needs more than a
  # few committed world-writes/s. Tune from telemetry.
  @session_rate 5
  @session_burst 10
  @principal_rate 15
  @principal_burst 30
  @disconnect_after_drops 20
  @idle_ttl_ms 600_000
  @sweep_interval_ms 120_000

  @type session_id :: term()
  @type principal :: term()
  @type decision :: :ok | {:drop, :rate} | {:disconnect, :rate}

  ## Client API

  @doc "Start the limiter, creating its ETS table. Named — one per node."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  The hot path: decide whether a command from `session_id` (owned by the
  server-resolved `principal`) may proceed. Runs entirely in the CALLING
  process over ETS — no GenServer round-trip.

  Returns `:ok` to proceed, `{:drop, :rate}` to discard this one command
  (graceful "too fast"), or `{:disconnect, :rate}` when the session has
  sustained enough drops to be torn down. Fails OPEN (`:ok` + a telemetry
  alarm) on any unexpected error.
  """
  @spec check(session_id(), principal()) :: decision()
  def check(session_id, principal) do
    cfg = config()
    now = now_ms()

    s_key = {:session, session_id}
    p_key = {:principal, principal}

    s_tokens = refilled_tokens(s_key, cfg.session_rate, cfg.session_burst, now)
    p_tokens = refilled_tokens(p_key, cfg.principal_rate, cfg.principal_burst, now)

    if s_tokens >= 1.0 and p_tokens >= 1.0 do
      # ACCEPT: decrement + advance both buckets. With float tokens the
      # fractional accrual is already credited, so setting last := now is
      # exact (no under-crediting).
      :ets.insert(@table, {s_key, s_tokens - 1.0, now})
      :ets.insert(@table, {p_key, p_tokens - 1.0, now})
      reset_drops(session_id)
      :ok
    else
      # REJECT: consume nothing, write nothing — the refill recomputes from
      # the stored last_refill_ms on the next check (monotonic), and not
      # writing keeps the flood path cheap.
      escalate(session_id, cfg.disconnect_after_drops)
    end
  rescue
    e -> fail_open(:error, e)
  catch
    kind, reason -> fail_open(kind, reason)
  end

  @doc """
  Monitor `pid` (a spawned `PlayerSession`) so its per-session bucket and
  drop-counter are reaped automatically when it dies. Call once at spawn,
  next to `SessionLimit.attach/2`.
  """
  @spec watch(pid()) :: :ok
  def watch(pid) when is_pid(pid), do: GenServer.cast(__MODULE__, {:watch, pid})

  @doc """
  Drop `session_id`'s per-session bucket + drop-counter. Called on
  session-down (also reached automatically via `watch/1`'s monitor);
  idempotent and never raises.
  """
  @spec forget(session_id()) :: :ok
  def forget(session_id) do
    :ets.delete(@table, {:session, session_id})
    :ets.delete(@table, {:drops, session_id})
    :ok
  catch
    _, _ -> :ok
  end

  @doc false
  def table, do: @table

  ## Server

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_cast({:watch, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, %{state | monitors: Map.put(state.monitors, ref, pid)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {pid, monitors} ->
        forget(pid)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_idle()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  # Read a bucket, lazily refilling to now. Absent => a full (burst) bucket.
  defp refilled_tokens(key, rate, burst, now) do
    case :ets.lookup(@table, key) do
      [{^key, tokens, last}] ->
        gained = (now - last) * rate / 1000.0
        min(burst * 1.0, tokens + gained)

      [] ->
        burst * 1.0
    end
  end

  # Bump the consecutive-drop counter; disconnect once it crosses the
  # threshold, else a plain drop. Atomic per session (update_counter).
  defp escalate(session_id, threshold) do
    n = :ets.update_counter(@table, {:drops, session_id}, {2, 1}, {{:drops, session_id}, 0})
    if n >= threshold, do: {:disconnect, :rate}, else: {:drop, :rate}
  end

  defp reset_drops(session_id), do: :ets.delete(@table, {:drops, session_id})

  # TTL-expire any bucket row (3-tuple {key, tokens, last}) untouched for
  # longer than idle_ttl_ms. Drop-counter rows are 2-tuples and never match
  # this 3-element pattern, so they're left to the per-session monitor reap.
  defp sweep_idle do
    cutoff = now_ms() - idle_ttl_ms()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  catch
    _, _ -> 0
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  defp fail_open(kind, reason) do
    :telemetry.execute(
      [:commonplace, :mud, :rate_limit, :fail_open],
      %{count: 1},
      %{kind: kind, reason: reason}
    )

    Logger.error("RateLimit.check failed open (allowing command): #{inspect(kind)} #{inspect(reason)}")
    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp config do
    cfg = Application.get_env(:commonplace, :mud_rate_limit, [])

    %{
      session_rate: Keyword.get(cfg, :session_rate, @session_rate),
      session_burst: Keyword.get(cfg, :session_burst, @session_burst),
      principal_rate: Keyword.get(cfg, :principal_rate, @principal_rate),
      principal_burst: Keyword.get(cfg, :principal_burst, @principal_burst),
      disconnect_after_drops: Keyword.get(cfg, :disconnect_after_drops, @disconnect_after_drops)
    }
  end

  defp idle_ttl_ms do
    Application.get_env(:commonplace, :mud_rate_limit, [])
    |> Keyword.get(:idle_ttl_ms, @idle_ttl_ms)
  end

  defp sweep_interval_ms do
    Application.get_env(:commonplace, :mud_rate_limit, [])
    |> Keyword.get(:sweep_interval_ms, @sweep_interval_ms)
  end
end
