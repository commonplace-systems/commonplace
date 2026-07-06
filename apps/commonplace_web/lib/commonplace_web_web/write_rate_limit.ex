defmodule CommonplaceWebWeb.WriteRateLimit do
  @moduledoc """
  CX-qat5.6 (M1 safe subset): per-connection browser write rate
  limiting — the one concrete safety rail for the non-enforced
  social-contract tier, protecting the shared single-node server from
  one flooding browser session.

  Deliberately identity-independent: the limiter is keyed on the
  CONNECTION (the calling LiveView process — pass `self()` from a
  `handle_event` callback), not on user identity. Real per-user
  identity/signing is deferred; this only bounds how fast any one
  open tab can hammer the write path.

  ## Algorithm

  RAM-resident sliding window, mirroring the style of
  `Commonplace.Bots.RateLimit`: each key maps to a list of monotonic
  timestamps of its recent writes. `check_and_record/1` prunes
  timestamps older than `window_ms`, and if what's left is under
  `max_writes` it records a new timestamp and returns `:ok`;
  otherwise it returns `{:error, :rate_limited, retry_after_ms}`
  without recording (a rejected call does not itself count against
  the window).

  Default: 30 writes / 10s, configurable via

      config :commonplace_web, :write_rate_limit, max_writes: 30, window_ms: 10_000

  or at runtime via `config/1` (used by tests).

  ## Eviction (memory)

  A connection key is typically a LiveView pid, so a flood of
  short-lived browser connections could otherwise leak one map entry
  per pid forever. Two layers close that:

    1. The sliding window itself ages out old timestamps on every
       access — a key that stops being written to naturally shrinks
       to an empty list.
    2. A periodic sweep (`handle_info(:sweep, ...)`, default every
       `window_ms`) walks the map and deletes any key whose list is
       empty after pruning, so idle connections don't sit around as
       zero-length list entries indefinitely. `sweep/0` runs it
       synchronously (used by tests instead of waiting on the timer).

  A key that's fully evicted just starts over with a fresh full
  allowance next time it's seen — that's fine: eviction only happens
  once the key has been quiet for a full window, i.e. it wasn't at
  its limit anyway.
  """

  use GenServer

  @default_max_writes 30
  @default_window_ms 10_000

  defstruct config: nil, writes: %{}, sweep_ref: nil

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check the sliding window for `key` and, if under the limit, record
  this write. `key` should be stable for the connection's lifetime
  (e.g. the LiveView's own pid, `self()`, called from inside a
  `handle_event` callback) — NOT tied to user identity.
  """
  @spec check_and_record(term()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check_and_record(key), do: GenServer.call(__MODULE__, {:check_and_record, key})

  @doc "Set process-wide limits (used by tests)."
  @spec config(keyword()) :: :ok
  def config(opts), do: GenServer.call(__MODULE__, {:config, opts})

  @doc "Number of keys currently tracked (test/introspection helper)."
  @spec key_count() :: non_neg_integer()
  def key_count, do: GenServer.call(__MODULE__, :key_count)

  @doc "Force an immediate sweep of idle keys (test helper; also runs periodically)."
  @spec sweep() :: :ok
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  ## GenServer

  @impl true
  def init(opts) do
    config = build_config(opts)
    ref = schedule_sweep(config.window_ms)
    {:ok, %__MODULE__{config: config, sweep_ref: ref}}
  end

  defp build_config(opts) do
    app_env = Application.get_env(:commonplace_web, :write_rate_limit, [])

    %{
      max_writes: Keyword.get(opts, :max_writes, Keyword.get(app_env, :max_writes, @default_max_writes)),
      window_ms: Keyword.get(opts, :window_ms, Keyword.get(app_env, :window_ms, @default_window_ms))
    }
  end

  defp schedule_sweep(window_ms) do
    Process.send_after(self(), :sweep, max(window_ms, 1))
  end

  @impl true
  def handle_call({:check_and_record, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.config.window_ms
    kept = prune(Map.get(state.writes, key, []), cutoff)

    if length(kept) >= state.config.max_writes do
      oldest = List.last(kept)
      retry_after_ms = max(oldest + state.config.window_ms - now, 1)
      state = %{state | writes: Map.put(state.writes, key, kept)}
      {:reply, {:error, :rate_limited, retry_after_ms}, state}
    else
      state = %{state | writes: Map.put(state.writes, key, [now | kept])}
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:config, opts}, _from, state) do
    {:reply, :ok, %{state | config: build_config(opts)}}
  end

  @impl true
  def handle_call(:key_count, _from, state) do
    {:reply, map_size(state.writes), state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, :ok, do_sweep(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = do_sweep(state)
    ref = schedule_sweep(state.config.window_ms)
    {:noreply, %{state | sweep_ref: ref}}
  end

  defp do_sweep(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.config.window_ms

    writes =
      state.writes
      |> Enum.reduce(%{}, fn {key, list}, acc ->
        case prune(list, cutoff) do
          [] -> acc
          kept -> Map.put(acc, key, kept)
        end
      end)

    %{state | writes: writes}
  end

  defp prune(list, cutoff), do: Enum.filter(list, fn ts -> ts >= cutoff end)
end
