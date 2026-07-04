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

  * `[:commonplace, :commit_store, :call]` - CommitStore write-verb
    handle_call completed (CX-9hql, R4c rung-0). Emitted once per
    WRITE-verb handle_call in `Commonplace.Store.CommitStore`, at reply
    time. Read verbs (`get_commit`, `commit_log`, `latest_commit`, ...)
    do NOT emit this — they mostly bypass the GenServer via
    `persistent_term` already (CX-tdkq.4).
    * Measurements: `%{duration: native_time, queue_len: integer}` —
      `duration` is the handle_call body's wall time; `queue_len` is
      `Process.info(self(), :message_queue_len)` sampled at handle_call
      ENTRY, i.e. how many callers were already waiting behind this one
      (the rung-2 mailbox-pressure signal).
    * Metadata: `%{verb: atom, doc_uuid: string | nil}` — `verb` is one
      of `:create_commit`, `:create_chained_commit`,
      `:write_snapshot_cas`, `:write_prebuilt_commit_cas`,
      `:import_commit`, `:store_capability` (`doc_uuid` is `nil` for
      `:store_capability`, which isn't doc-keyed).

  * `[:commonplace, :commit_store, :write_cpu]` - CPU-share breakdown
    inside the serialized section (CX-9hql, R4c rung-0). Emitted for the
    two commit-building paths that do CPU work inside a handle_call:
    the `create_commit`/`create_chained_commit` family and
    `import_commit`.
    * Measurements: `%{build: native_time, sign: native_time,
      validate: native_time, persist: native_time}` — each phase is 0
      for a verb that doesn't run it (e.g. `import_commit` never runs
      `build`/`sign`; the create family never runs `validate`).
      `build` = `Commit.new/4` (content-addressing/hashing); `sign` =
      `maybe_sign_commit/2`; `validate` = `Commit.verify_id/1` plus the
      trust/namespace/code-doc-heuristic gate chain (import path only);
      `persist` = the CubDB put(s).
    * Metadata: `%{verb: atom, doc_uuid: string}`.

  * `[:commonplace, :commit_store, :queue_depth]` - periodic CommitStore
    mailbox-depth sample (CX-9hql, R4c rung-0), emitted by the companion
    `Commonplace.Store.CommitStoreQueuePoller` process. Entry-sampled
    `queue_len` on `:call` only fires when a call is PROCESSED, so a
    genuine stall (mailbox deep, nothing draining it) would otherwise go
    silent; this poller samples the mailbox from a separate process on a
    timer so it stays visible during a stall too. Ticks every
    `Application.get_env(:commonplace, :commit_store_queue_poll_ms,
    5_000)` milliseconds; set that to `nil` or `false` to disable
    (disabled by default in the test env — see `config/test.exs`).
    * Measurements: `%{queue_len: integer}`.
    * Metadata: `%{store: atom}` — the store's registered name.

  ## R4c trigger threshold (draft)

  DRAFT — to be finalized with commonplace-plan once this telemetry has
  produced real production-shaped data. The R4c decision rejected
  CommitStore write-sharding (coordinator-sharding, "option B") absent
  evidence and required rung-1/rung-2 instrumentation first (this bead);
  CX-3erd hoists CPU out of the serialized section next. Sharding is
  reconsidered only if telemetry shows SUSTAINED CommitStore mailbox
  pressure under many-doc concurrent write load AFTER CX-3erd lands.

  Draft criterion: `queue_len` p95 > 25 sustained over a 60-second
  window, with the waiting calls spread across ≥ 8 distinct
  `doc_uuid`s, met in ≥ 3 such windows within a 7-day period (a single
  tripped window is more likely a one-off burst or GC pause than a
  structural bottleneck — a recurrence bar distinguishes the two).
  Single-doc queueing does NOT count toward this bar — it's inherent
  serial-point work for that doc that per-doc sharding can't help
  either way.

  The `25` in "p95 > 25" is a PLACEHOLDER pending baseline data — it
  should be re-set relative to an observed production-shaped baseline
  (e.g. "> 10× baseline p95") once this telemetry has run for a few
  weeks, not treated as a load-bearing number today.

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
      [:commonplace, :process, :stop],
      [:commonplace, :commit_store, :call],
      [:commonplace, :commit_store, :write_cpu]
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

  def handle_event([:commonplace, :commit_store, :call], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug(
      "[commit_store] #{metadata.verb} doc=#{inspect(metadata.doc_uuid)} " <>
        "#{duration_ms}ms queue_len=#{measurements.queue_len}"
    )
  end

  def handle_event([:commonplace, :commit_store, :write_cpu], measurements, metadata, _config) do
    Logger.debug(
      "[commit_store] #{metadata.verb} doc=#{metadata.doc_uuid} write_cpu " <>
        "build=#{measurements.build} sign=#{measurements.sign} " <>
        "validate=#{measurements.validate} persist=#{measurements.persist}"
    )
  end
end
