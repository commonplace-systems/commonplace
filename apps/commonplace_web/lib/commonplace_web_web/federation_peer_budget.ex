defmodule CommonplaceWebWeb.FederationPeerBudget do
  @moduledoc """
  Per-peer deferral budget for the federation import endpoint (the
  CX-orfw.1 scope note: bound each peer's contribution to CommitStore's
  `pending_imports` queue, so one peer flooding `:awaiting_capability`
  commits can't exhaust the GLOBAL `@max_pending_imports` cap and starve
  other peers' legitimate deferrals).

  Fixed-window counter: a deferral increments the peer's count for the
  current window bucket; `over_budget?/1` checks the current bucket
  against the configured max. Config:

      config :commonplace_web, :federation_deferral_budget, {32, 60_000}

  Counting DEFERRALS (not requests) is deliberate — a well-behaved peer
  inlines certs in its envelopes and never defers, so its budget is
  never touched; request-level rate limiting can layer on separately.
  """
  use GenServer

  @table __MODULE__
  @default_budget {32, 60_000}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @doc "Has this peer used up its deferral budget for the current window?"
  def over_budget?(peer) do
    {max, window_ms} = budget()
    count(peer, bucket(window_ms)) >= max
  end

  @doc "Record one deferred import for this peer."
  def record_deferral(peer) do
    {_max, window_ms} = budget()
    :ets.update_counter(@table, {peer, bucket(window_ms)}, 1, {{peer, bucket(window_ms)}, 0})
    :ok
  end

  @doc "Clear all counters (test helper)."
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp count(peer, bucket) do
    case :ets.lookup(@table, {peer, bucket}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  defp bucket(window_ms), do: div(System.system_time(:millisecond), window_ms)

  defp budget do
    Application.get_env(:commonplace_web, :federation_deferral_budget, @default_budget)
  end
end
