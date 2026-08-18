defmodule Commonplace.Trust.AuditLogCounter do
  @moduledoc """
  Per-BEAM-boot counters for the stage boundaries in `AuditLog.handle_event/4`.

  ⚠️ **TWO OF THESE FIELDS COUNT DIFFERENT THINGS, AND THE DIFFERENCE IS LOAD-BEARING.**

    * `offered`      — calls to `AuditDispatcher.offer/2`, i.e. RECORDS
    * `offer_events` — EVENTS that reached the offer stage

  They differ because `AuditRateLimiter` offers expired-window summaries from
  its supervised timer, outside any input event. So `offered` answers "how many
  records did the dispatcher get" and `offer_events` answers "how many input
  events got that far", and only the second one belongs in a sum with `guarded`
  / `rate_suppressed` / `handler_failed`.

  ⛔ **THE STAGE IDENTITY IS OVER EVENTS, NEVER OVER `offered`:**

      entered == guarded + rate_suppressed + offer_events + handler_failed

  Using `offered` there is arithmetic across two populations. It holds only
  while no summary has ever been emitted, which is the common case and is
  exactly why it survives casual testing — then breaks on the first timer flush
  with suppressions, in a direction that looks like a lost event.

  ⭐ This is the same defect `Trust.capture_rate/1` shipped as a RATIO and had
  to be fixed after deploy. It is recorded here because an equality makes it
  much harder to see than a division did.

  The atomics reference is held in `:persistent_term`, matching `DenialCounter`,
  and the snapshot carries that counter's `boot_id` so every value is explicitly
  scoped to this boot.
  """

  alias Commonplace.Trust.DenialCounter

  @key {__MODULE__, :boot_counter}
  @stages [
    :entered,
    :built,
    :guarded,
    :rate_suppressed,
    :offered,
    :handler_failed,
    :offer_events
  ]

  @doc false
  def init do
    case :persistent_term.get(@key, :missing) do
      :missing ->
        counters = :atomics.new(length(@stages), signed: false)
        :persistent_term.put(@key, {DenialCounter.boot_id(), counters})
        :ok

      {_boot_id, _counters} ->
        :ok
    end
  end

  @doc false
  @spec increment(
          :entered
          | :built
          | :guarded
          | :rate_suppressed
          | :offered
          | :handler_failed
          | :offer_events
        ) :: non_neg_integer()
  def increment(stage) do
    {_boot_id, counters} = state()
    :atomics.add_get(counters, index(stage), 1)
  end

  @doc "Return all `AuditLog.handle_event/4` stage counts for this BEAM boot."
  @spec snapshot() :: %{
          boot_id: String.t(),
          entered: non_neg_integer(),
          built: non_neg_integer(),
          guarded: non_neg_integer(),
          rate_suppressed: non_neg_integer(),
          offered: non_neg_integer(),
          handler_failed: non_neg_integer(),
          offer_events: non_neg_integer()
        }
  def snapshot do
    {boot_id, counters} = state()

    Enum.with_index(@stages, 1)
    |> Map.new(fn {stage, index} -> {stage, :atomics.get(counters, index)} end)
    |> Map.put(:boot_id, boot_id)
  end

  defp state do
    case :persistent_term.get(@key, :missing) do
      :missing ->
        init()
        :persistent_term.get(@key)

      state ->
        state
    end
  end

  defp index(:entered), do: 1
  defp index(:built), do: 2
  defp index(:guarded), do: 3
  defp index(:rate_suppressed), do: 4
  defp index(:offered), do: 5
  defp index(:handler_failed), do: 6
  defp index(:offer_events), do: 7
end
