defmodule Commonplace.Trust.AuditLog do
  @moduledoc """
  Durable audit trail for trust-decision events (CX-hilo).

  ## The gap this closes

  `Commonplace.Trust` and its callers emit three telemetry events on
  every rejected write, ignored revocation, and (in `:dry_run`) refused
  read:

    * `[:commonplace, :commit, :rejected, :local_trust]` — `commit_store.ex`
    * `[:commonplace, :trust, :revocation, :ignored]` — `trust/verify_chain.ex`
    * `[:commonplace, :trust, :read, :would_refuse]` — `trust/read.ex`

  `:telemetry.execute/3` is fire-and-forget: absent a handler, these
  events vanish. A security-incident review ("who was denied what, when,
  under which cert") had no data source on a live serve unless someone
  happened to be tailing logs at the time. This module attaches a
  handler for all three events at app boot and persists a compact
  record of each into `Commonplace.Dataflow.RedLog` — the house pattern
  for durable, append-only, gold-attested event history (the same
  mechanism GitBridge uses for its own event stream, readable via the
  MCP `tail_red` tool).

  This is **observation only**. The handler never returns a value the
  gate consults, never raises into the caller (telemetry handler crashes
  are caught and logged by `:telemetry` itself, but see the flood guard
  below for why they shouldn't happen), and does not change which writes
  or reads are allowed.

  ## Where the events land

  All three event names write into a single, deterministically-derived
  red log doc UUID (`log_uuid/0`), the same "stable UUID from a fixed
  seed" idiom `Commonplace.Presence.Mailbox.log_uuid_for_identity/1`
  uses — no schema entry or provisioning step needed, and every node in
  a cluster computes the same UUID so the log is naturally shared
  (commits to the same doc UUID replicate over the existing `sync:`
  channel). Tail it with the MCP `tail_red` tool, or
  `Commonplace.Dataflow.RedLog.load(Commonplace.Trust.AuditLog.log_uuid())
  |> Commonplace.Dataflow.RedLog.read()`.

  ## Retention

  `RedLog` is an append-only YArray doc — same growth story as any
  other long-lived red log (see CX-4rec: unbounded doc growth becomes a
  problem "when it matters", at which point the fix is period-rolling,
  not something this module invents). The flood guard below keeps this
  particular log's growth rate bounded well below the threshold where
  that would bite, so no rotation logic is added here.

  ## Flood guard

  `[:commonplace, :trust, :read, :would_refuse]` fires on every refused
  read while `:local_read_gate` is `:dry_run` — a citizen polling a
  denied resource in a loop could emit hundreds of these a second, and
  writing a chained commit per event would both flood the red log doc
  and hammer the CommitStore. Each event name gets its own token bucket:
  at most `@cap` (#{20}) events are persisted per 60-second window; the
  rest are only counted. When a window rolls over, if any events were
  suppressed a single summary record (`"summary" => true, "suppressed"
  => n`) is written for the window that just closed, so the audit trail
  still shows *that* a flood happened and *how big*, without paying for
  each one. Worst case this module writes `@cap + 1` red-log commits per
  event name per minute — bounded and cheap regardless of how hot the
  underlying loop runs.
  """

  require Logger

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStoreClient

  @handler_id "commonplace-trust-audit-log"

  @events [
    [:commonplace, :commit, :rejected, :local_trust],
    [:commonplace, :trust, :revocation, :ignored],
    [:commonplace, :trust, :read, :would_refuse]
  ]

  @rate_table :commonplace_trust_audit_log_rate
  @window_ms 60_000
  @cap 20

  @doc "The deterministic red-log doc UUID this module writes into."
  def log_uuid do
    UUID.uuid5(:url, "urn:commonplace:trust-audit-log")
  end

  @doc """
  Attach the audit handler. Idempotent — safe to call repeatedly (e.g.
  across app restarts in the same BEAM instance, or from tests), same
  detach/attach idiom `Commonplace.Reflog.Snapshot`'s dirty-tracker uses
  in `Commonplace.Application`.
  """
  def attach(store \\ CommitStoreClient) do
    ensure_rate_table()
    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      %{store: store}
    )
  end

  @doc "Detach the audit handler."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(event_name, measurements, metadata, %{store: store}) do
    payload = build_payload(event_name, measurements, metadata)

    case rate_gate(event_name) do
      {:log, nil} ->
        persist(store, payload)

      {:log, summary} ->
        persist(store, summary)
        persist(store, payload)

      :suppress ->
        :ok
    end
  rescue
    error ->
      # Observation only: a bug in this handler must never propagate
      # into the caller that fired the telemetry event (a trust-gate
      # denial path, of all places). Log and swallow.
      Logger.warning("Commonplace.Trust.AuditLog: handler failed: #{inspect(error)}")
      :ok
  end

  defp persist(store, event_map) do
    log = RedLog.load(log_uuid(), store)
    log = RedLog.append_raw(log, event_map)
    _ = RedLog.commit(log)
    :ok
  end

  # --- payload shaping ---

  defp build_payload(
         [:commonplace, :commit, :rejected, :local_trust] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "doc_uuid" => Map.get(metadata, :doc_uuid),
      "commit_id" => encode_id(Map.get(metadata, :commit_id)),
      "mode" => Map.get(metadata, :mode),
      "reason" => inspect(Map.get(metadata, :reason)),
      "system_time" => Map.get(measurements, :system_time)
    }
  end

  defp build_payload(
         [:commonplace, :trust, :revocation, :ignored] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "cap_id" => encode_id(Map.get(metadata, :cap_id)),
      "revoker_pubkey" => encode_id(Map.get(metadata, :revoker_pubkey)),
      "system_time" => Map.get(measurements, :system_time)
    }
  end

  defp build_payload(
         [:commonplace, :trust, :read, :would_refuse] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "doc_uuid" => Map.get(metadata, :target),
      "reader" => Map.get(metadata, :reader),
      "surface" => Map.get(metadata, :surface),
      "visibility" => Map.get(metadata, :visibility),
      "count" => Map.get(measurements, :count, 1)
    }
  end

  defp encode_id(id) when is_binary(id) do
    if String.printable?(id), do: id, else: Base.encode16(id, case: :lower)
  end

  defp encode_id(other), do: other

  # --- flood guard: per-event-name token bucket + window summary ---

  defp ensure_rate_table do
    if :ets.whereis(@rate_table) == :undefined do
      :ets.new(@rate_table, [:named_table, :public, :set])
    end

    :ok
  end

  # Returns {:log, nil} to persist normally, {:log, summary_map} to
  # persist a summary for the window just closed AND persist this
  # event, or :suppress to drop this event (already over cap this
  # window).
  defp rate_gate(event_name) do
    ensure_rate_table()
    now = System.system_time(:millisecond)

    case :ets.lookup(@rate_table, event_name) do
      [{^event_name, window_start, count, suppressed}] when now - window_start < @window_ms ->
        if count < @cap do
          :ets.insert(@rate_table, {event_name, window_start, count + 1, suppressed})
          {:log, nil}
        else
          :ets.insert(@rate_table, {event_name, window_start, count, suppressed + 1})
          :suppress
        end

      [{^event_name, window_start, _count, suppressed}] ->
        # Window rolled over — start a fresh one, this event is #1 in it.
        :ets.insert(@rate_table, {event_name, now, 1, 0})

        summary =
          if suppressed > 0 do
            %{
              "event" => "audit_log.rate_limited",
              "suppressed_event" => Enum.join(event_name, "."),
              "window_start_ms" => window_start,
              "window_ms" => @window_ms,
              "suppressed" => suppressed,
              "summary" => true
            }
          end

        {:log, summary}

      [] ->
        :ets.insert(@rate_table, {event_name, now, 1, 0})
        {:log, nil}
    end
  end
end
