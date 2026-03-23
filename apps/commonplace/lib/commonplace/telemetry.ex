defmodule Commonplace.Telemetry do
  @moduledoc """
  Telemetry events emitted by Commonplace.

  ## Events

  * `[:commonplace, :sync, :start]` - Sync cycle started
    * Measurements: `%{system_time: integer}`
    * Metadata: `%{root_uuid: string, dir: string}`

  * `[:commonplace, :sync, :stop]` - Sync cycle completed
    * Measurements: `%{duration: integer, changes: integer}`
    * Metadata: `%{root_uuid: string, dir: string}`

  * `[:commonplace, :commit, :create]` - Commit created
    * Measurements: `%{system_time: integer}`
    * Metadata: `%{doc_uuid: string}`

  * `[:commonplace, :orchestrator, :reconcile]` - Reconciliation completed
    * Measurements: `%{duration: integer}`
    * Metadata: `%{added: integer, removed: integer, changed: integer, total: integer}`

  * `[:commonplace, :process, :start]` - Managed process started
    * Measurements: `%{system_time: integer}`
    * Metadata: `%{name: string, mode: atom}`

  * `[:commonplace, :process, :stop]` - Managed process stopped
    * Measurements: `%{system_time: integer}`
    * Metadata: `%{name: string}`

  ## Console Logger

  `Commonplace.Telemetry` provides `attach_console_logger/0` which logs
  events to the Elixir Logger for easy debugging.
  """

  require Logger

  @doc "Attach the console logger for all commonplace telemetry events."
  def attach_console_logger do
    events = [
      [:commonplace, :sync, :stop],
      [:commonplace, :commit, :create],
      [:commonplace, :orchestrator, :reconcile],
      [:commonplace, :process, :start],
      [:commonplace, :process, :stop]
    ]

    :telemetry.attach_many(
      "commonplace-console-logger",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc "Detach the console logger."
  def detach_console_logger do
    :telemetry.detach("commonplace-console-logger")
  end

  @doc false
  def handle_event([:commonplace, :sync, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("[sync] #{metadata.dir} — #{measurements.changes} changes in #{duration_ms}ms")
  end

  def handle_event([:commonplace, :commit, :create], _measurements, metadata, _config) do
    Logger.debug("[commit] #{metadata.doc_uuid}")
  end

  def handle_event([:commonplace, :orchestrator, :reconcile], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if metadata.added > 0 or metadata.removed > 0 or metadata.changed > 0 do
      Logger.info(
        "[orchestrator] reconcile in #{duration_ms}ms — +#{metadata.added} -#{metadata.removed} ~#{metadata.changed} (#{metadata.total} total)"
      )
    end
  end

  def handle_event([:commonplace, :process, :start], _measurements, metadata, _config) do
    Logger.info("[process] started #{metadata.name} (#{metadata.mode})")
  end

  def handle_event([:commonplace, :process, :stop], _measurements, metadata, _config) do
    Logger.info("[process] stopped #{metadata.name}")
  end
end
