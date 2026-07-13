defmodule Commonplace.MUD.SessionLimit do
  @moduledoc """
  CX-z0v7 (condition 2): the UNIFIED serve-side session-resource bound
  covering BOTH web (`CommonplaceWebWeb.MudLive`) and bot
  (`Commonplace.MUD.Bot.spawn_session/2`) `PlayerSession` spawns — ONE
  cap, not two. `CX-nf8p` (the web rate-limit bead) is expected to
  reference THIS module rather than adding a second concurrent-session
  cap of its own.

  Enforces two caps, both config-driven from app-env:

      Application.get_env(:commonplace, :mud_session_limit, [])
      # max_total: 64, max_per_principal: 8 (defaults)

  Config is read fresh on every `admit/1` call (not cached at
  `start_link/1` time) so tests can retune the caps without restarting
  the (singleton, unconditionally-started) GenServer.

  ## Reserve-before-spawn, attach-after

  Callers are expected to:

    1. `admit(principal)` BEFORE spawning the `PlayerSession` —
       atomically checks both caps and, if under them, reserves a slot
       under a fresh `ref`, returning `{:ok, ref}`. A reservation counts
       toward both the total and per-principal caps until it is
       attached or released, so two callers racing on the same
       principal can't both slip past a per-principal cap while their
       spawns are in flight.
    2. `attach(ref, pid)` AFTER the session spawns successfully — binds
       the reservation to the live `pid` and starts monitoring it, so
       the slot is freed automatically (`handle_info({:DOWN, ...})`)
       whenever the session process dies, restart or crash alike.
    3. `release(ref)` if the spawn itself failed — frees the
       reservation without ever having a pid to monitor.

  A reservation that's admitted but never attached or released (e.g.
  the calling process crashes between `admit/1` and the `attach/2` /
  `release/1` call) is also guarded: `admit/1` monitors the CALLING
  process too, and drops the reservation if the caller dies first.

  ## Scope: restart-not-durable, generous backstop

  Like `Commonplace.MUD.SessionViewRegistry`, this is plain in-process
  state (a monitor-per-slot map) — a serve restart drops it and every
  session starts uncounted again from zero, which is fine: it's a
  resource-exhaustion backstop against a runaway (a bug spawning
  thousands of sessions, or a single principal opening far more
  concurrent sessions than any normal player would), NOT a
  tightly-tuned quota. The defaults are deliberately generous — they
  must NEVER bite normal single-operator (or small multiplayer) play,
  only a real leak or abuse case.
  """

  use GenServer

  @default_max_total 64
  @default_max_per_principal 8

  @type principal :: term()
  @type ref_t :: reference()

  ## Client API

  @doc "Start the limiter, empty. Named `__MODULE__` — one per node."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Reserve a session slot for `principal` if both the total and
  per-principal caps allow it. Returns `{:ok, ref}` on success — the
  caller must follow up with `attach/2` (spawn succeeded) or
  `release/1` (spawn failed) using that `ref`. Returns
  `{:error, :session_limit}` if either cap is already at/over its
  limit (reservations count toward the cap, so in-flight spawns can't
  race past it).
  """
  @spec admit(principal()) :: {:ok, ref_t()} | {:error, :session_limit}
  def admit(principal) do
    GenServer.call(__MODULE__, {:admit, principal, self()})
  end

  @doc """
  Bind a previously-reserved `ref` to the now-spawned session `pid` and
  start monitoring it, so the slot auto-frees when the session dies.
  No-op if `ref` is unknown (already released, or never reserved).
  """
  @spec attach(ref_t(), pid()) :: :ok
  def attach(ref, pid) when is_reference(ref) and is_pid(pid) do
    GenServer.call(__MODULE__, {:attach, ref, pid})
  end

  @doc """
  Release a reserved-but-never-attached slot (the spawn it was held
  for failed). No-op if `ref` is unknown or already attached.
  """
  @spec release(ref_t()) :: :ok
  def release(ref) when is_reference(ref) do
    GenServer.call(__MODULE__, {:release, ref})
  end

  @doc "Introspection: live + reserved counts, total and per-principal."
  @spec count() :: %{total: non_neg_integer(), by_principal: %{principal() => non_neg_integer()}}
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @doc """
  The pids of ATTACHED (`:live`) sessions — every live session of every kind
  (web/bot/MCP/ephemeral all `admit+attach`). The authoritative liveness tracker
  the `GhostReaper` reads (with `PresenceRegistry`) to build its fail-closed
  dead-in-both live-set. Reserved-but-not-yet-attached slots are excluded (no pid
  yet). Raises/exits if the limiter isn't running — the reaper treats that as
  live-set incompleteness and aborts the run (fail-closed).
  """
  @spec live_pids() :: [pid()]
  def live_pids do
    GenServer.call(__MODULE__, :live_pids)
  end

  ## Server

  # Slots are keyed by `ref` (a fresh `make_ref/0` per reservation):
  #
  #   {principal, :reserved, caller_ref}       -- admitted, not yet attached
  #   {principal, :live, pid, monitor_ref}     -- attached, session alive
  #
  # `monitors` maps a monitor reference -> the slot `ref` it belongs to,
  # for both the caller-crash guard (reserved) and the session-death
  # guard (live), so a single `handle_info({:DOWN, ...})` clause covers
  # both cases uniformly.
  defstruct slots: %{}, monitors: %{}

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:admit, principal, caller_pid}, _from, state) do
    %{max_total: max_total, max_per_principal: max_per_principal} = limits()

    total = map_size(state.slots)
    per_principal = count_for_principal(state.slots, principal)

    if total >= max_total or per_principal >= max_per_principal do
      {:reply, {:error, :session_limit}, state}
    else
      ref = make_ref()
      caller_ref = Process.monitor(caller_pid)

      slots = Map.put(state.slots, ref, {principal, :reserved, caller_ref})
      monitors = Map.put(state.monitors, caller_ref, ref)

      {:reply, {:ok, ref}, %{state | slots: slots, monitors: monitors}}
    end
  end

  @impl true
  def handle_call({:attach, ref, pid}, _from, state) do
    case Map.get(state.slots, ref) do
      {principal, :reserved, caller_ref} ->
        Process.demonitor(caller_ref, [:flush])
        monitors = Map.delete(state.monitors, caller_ref)

        monitor_ref = Process.monitor(pid)
        slots = Map.put(state.slots, ref, {principal, :live, pid, monitor_ref})
        monitors = Map.put(monitors, monitor_ref, ref)

        {:reply, :ok, %{state | slots: slots, monitors: monitors}}

      _other_or_nil ->
        # Unknown ref (already released/attached, or never reserved) —
        # a no-op, per the documented contract.
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:release, ref}, _from, state) do
    case Map.get(state.slots, ref) do
      {_principal, :reserved, caller_ref} ->
        Process.demonitor(caller_ref, [:flush])
        monitors = Map.delete(state.monitors, caller_ref)
        slots = Map.delete(state.slots, ref)
        {:reply, :ok, %{state | slots: slots, monitors: monitors}}

      _other_or_nil ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:count, _from, state) do
    by_principal =
      Enum.reduce(state.slots, %{}, fn {_ref, slot}, acc ->
        principal = elem(slot, 0)
        Map.update(acc, principal, 1, &(&1 + 1))
      end)

    {:reply, %{total: map_size(state.slots), by_principal: by_principal}, state}
  end

  @impl true
  def handle_call(:live_pids, _from, state) do
    pids = for {_ref, {_principal, :live, pid, _monitor_ref}} <- state.slots, do: pid
    {:reply, pids, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {slot_ref, monitors} ->
        # Whether this monitor belonged to a still-reserved slot (the
        # CALLER died before attach/release) or a live one (the session
        # itself died), the outcome is the same: drop the slot — its
        # single monitor is the one that just fired either way.
        {:noreply, %{state | slots: Map.delete(state.slots, slot_ref), monitors: monitors}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp count_for_principal(slots, principal) do
    Enum.count(slots, fn {_ref, slot} -> elem(slot, 0) == principal end)
  end

  defp limits do
    cfg = Application.get_env(:commonplace, :mud_session_limit, [])

    %{
      max_total: Keyword.get(cfg, :max_total, @default_max_total),
      max_per_principal: Keyword.get(cfg, :max_per_principal, @default_max_per_principal)
    }
  end
end
