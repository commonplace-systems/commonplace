defmodule Commonplace.Trust.AuditDispatcher do
  @moduledoc """
  The out-of-band writer for trust-denial audit records (CX-t3xv).

  ## Why this process exists

  `Commonplace.Trust.AuditLog` attaches a telemetry handler to the
  denial events. **Telemetry handlers run in the process that fired the
  event**, and the loudest denial event is fired from inside
  `Commonplace.Store.CommitStore`'s `handle_call`. The original handler
  persisted the record inline, which meant:

      CommitStore.handle_call
        -> handle_local_write_denial
          -> :telemetry.execute
            -> AuditLog.handle_event
              -> RedLog.commit
                -> CommitStoreClient.create_chained_commit
                  -> GenServer.call(THE SAME CommitStore)   ** :calling_self **

  The `:calling_self` exit is not an exception, so the handler's
  `rescue` never saw it; `:telemetry` caught it as `Class=:exit` and
  applied its crash policy, which is to **permanently detach the
  handler**. The first denial on a node therefore ended all denial
  auditing until restart — measured, with the stack trace above, in
  `Commonplace.Trust.AuditEnforceEtiologyTest`.

  This module is the R2-compliant answer, and it is deliberately the
  same shape as `Commonplace.Invariants.Dispatcher`: **a coalescing
  GenServer fed by a fire-and-forget `cast` from the emitting site, with
  the real work done in a `Task.Supervisor` task.** Nothing about
  persisting an audit record serializes behind the store's mailbox, and
  nothing about it serializes behind this mailbox either.

  ## What the deny site pays

  A `cast` and a map build. The allow path pays **nothing at all** —
  denial telemetry only fires on a denial, so the should-audit question
  is never asked when the answer is "no denial". That is the brief's §2
  "the allow path pays nothing" made structural rather than optimised.

  ## Bounded queue, LOUD loss counter

  Fire-and-forget alone loses records under pressure with no trace, and
  "an audit stream that can lose events silently is the silent-
  underreport pattern auditing itself" (brief §2). So the queue is
  bounded at `@max_queue` and every shed event increments a counter that
  is part of `status/0`, logs at `:warning`, and fires
  `[:commonplace, :trust, :audit, :shed]`.

  `status/0` obeys the denominator rule — the counts SUM:

      offered == recorded + shed + failed + guarded + queued + in_flight

  A report of "12 denials recorded" with no denominator cannot be
  distinguished from "1200 denials, 1188 shed". `status/0` refuses to
  let that happen; `accounted?/1` asserts the identity.

  ## No recursion through the gate

  An audit record is itself a write, and it goes through the ordinary
  signed path — it bypasses no gate. But a denial OF the audit write
  fires the very telemetry event this module handles, which would
  enqueue another audit write, which would be denied... The recursion is
  cut at the ENTRY, in `Commonplace.Trust.AuditLog.handle_event/4`: an
  event whose subject doc is the audit log's own doc is never enqueued.
  It is counted (`guarded`) and written to the local `Logger`, which is
  the fallback sink of last resort — outside the substrate, therefore
  outside the loop. See `AuditLog.recursion_guard/1`.

  ## Signing (CX-oc30, the other kill mechanism)

  Audit writes are signed with the **node** `%SigningContext{}`
  (`Commonplace.Crypto.NodeIdentity`), which `Commonplace.Trust`
  auto-trusts via `with_local_node_trust/1`. Without it the audit write
  is unsigned, and under `accept_unsigned: false` the gate refuses it:
  auditing a denial would itself be a denial. Measured green/red pair in
  `AuditEnforceEtiologyTest` etiology cases 4 and 5.

  If the node identity cannot be sourced the record is NOT written
  unsigned and hoped for — it is counted as `failed` and logged, because
  a write that will be refused is not an audit trail.

  ## Two mechanisms, one truth

  Mechanism **A** (in-band) is this process's counters plus the
  `[:commonplace, :trust, :audit, :recorded]` telemetry event.
  Mechanism **B** (substrate) is the red-log doc itself.

  `parity/1` compares them over this node's boot: every persisted record
  carries `"boot_id"`, so B's contribution from THIS node is countable
  without a shared clock or a cross-node convention. Disagreement is an
  alarm in its own right (brief §4) — two sinks that can silently
  diverge are worse than one.
  """

  use GenServer

  require Logger

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStoreClient

  # Deliberately modest. This queue exists to absorb a denial BURST
  # (a runaway citizen loop, a misconfigured peer), not to be a durable
  # spool — durability is the substrate doc's job, and a queue big
  # enough to hide a sustained overload would hide the overload.
  @max_queue 256

  # A drain writes up to this many records per commit. Batching is what
  # keeps a burst from turning into one CommitStore write per denial.
  @max_batch 64

  @default_flush_ms 250

  @doc """
  Starts the dispatcher.

  Options:

    * `:name` — registered name (default `__MODULE__`).
    * `:store` — the commit store (default `CommitStoreClient`).
    * `:enabled` — default `Application.get_env(:commonplace,
      :trust_audit_enabled, true)`. When false, offered events are
      counted as `shed` with reason `:disabled` — never silently
      dropped, because "auditing is off" is itself something an
      operator must be able to read off the counters.
    * `:flush_ms` — debounce before a drain (default 250).
    * `:max_queue` — queue bound (default 256).
    * `:task_supervisor` — where persist tasks run.
    * `:signing_context_fn` — arity-0 returning `{:ok, ctx}` /
      `{:error, reason}` (default `NodeIdentity.signing_context/0`).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Offer a denial record for persistence. Fire-and-forget by
  construction: this is called from inside `CommitStore`'s `handle_call`
  and must never block, never fail, and never care whether the
  dispatcher is even running.
  """
  @spec offer(GenServer.server(), map()) :: :ok
  def offer(server \\ __MODULE__, %{} = record) do
    GenServer.cast(server, {:audit, record})
  catch
    # A cast to a dead/unregistered name exits. The deny site is not a
    # place to raise from — the denial already happened and is already
    # returned to the caller; losing its RECORD must never turn into
    # losing its ENFORCEMENT.
    :exit, _ -> :ok
  end

  @doc """
  Ops/test visibility. Counts are cumulative since boot and they SUM —
  see the denominator rule in the moduledoc.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, reason -> %{error: {:dispatcher_unavailable, reason}}
  end

  @doc """
  Block until the queue has drained (or `timeout` elapses). Test/ops
  affordance only — nothing in the write path may call this.
  """
  @spec flush(GenServer.server(), timeout()) :: :ok | {:error, :timeout}
  def flush(server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, :flush, timeout)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc """
  The full denominator identity. It refuses the old dispatcher-only shape:
  callers must supply `emitted` and `upstream_loss`, normally by passing the
  result of `Commonplace.Trust.capture_rate/1`.
  """
  @spec accounted?(map()) :: boolean()
  def accounted?(
        %{
          emitted: emitted,
          upstream_loss: upstream_loss,
          offered: offered,
          pre_dispatcher_emitted: pre_dispatcher_emitted
        } = s
      )
      when upstream_loss >= 0 and pre_dispatcher_emitted >= 0 do
    emitted == pre_dispatcher_emitted + offered + upstream_loss and downstream_accounted?(s)
  end

  def accounted?(_), do: false

  @doc "The dispatcher-local identity, excluding loss before `offer/2`."
  @spec downstream_accounted?(map()) :: boolean()
  def downstream_accounted?(%{offered: offered} = s) do
    offered ==
      s.recorded + s.shed + s.failed + s.guarded + s.queued + s.in_flight
  end

  def downstream_accounted?(_), do: false

  @doc """
  The standing COUNT PARITY probe between mechanism A (in-band counters)
  and mechanism B (the substrate red-log doc), scoped to this node's
  boot.

  Returns a map with `:a`, `:b`, `:in_parity`, and — never a bare
  verdict — the shapes needed to act on a mismatch. `in_parity` is
  `false` when the two disagree, which is itself the alarm; suppressing
  either mechanism turns it red.

  **Compare at quiescence.** A's counter advances when a persist task
  reports back; B's records are visible the instant the commit lands.
  An in-flight batch can therefore put B legitimately ahead of A for a
  few milliseconds. Callers that want a verdict rather than a snapshot
  should `flush/2` first — `Commonplace.Trust.AuditCanary` does. The
  returned `:queued` and `:in_flight` are there so a caller that did not
  flush can tell a real divergence from a transient one.
  """
  @spec parity(GenServer.server()) :: map()
  def parity(server \\ __MODULE__) do
    case status(server) do
      %{error: _} = err ->
        Map.merge(err, %{in_parity: false, a: nil, b: nil, reason: :no_dispatcher})

      %{recorded: a, boot_id: boot_id, store: store} = s ->
        b = count_substrate_records(store, boot_id)

        %{
          a: a,
          b: b,
          boot_id: boot_id,
          in_parity: a == b,
          # Shapes, not just the verdict: a parity failure is
          # unactionable without knowing which side is short and what
          # else the dispatcher was doing.
          shed: s.shed,
          failed: s.failed,
          guarded: s.guarded,
          queued: s.queued,
          in_flight: s.in_flight
        }
    end
  end

  @doc false
  def count_substrate_records(store, boot_id) do
    Commonplace.Trust.AuditLog.log_uuid()
    |> RedLog.load(store)
    |> RedLog.read()
    |> Enum.count(&(is_map(&1) and Map.get(&1, "boot_id") == boot_id))
  rescue
    _ -> :unreadable
  catch
    _, _ -> :unreadable
  end

  # ── server ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      enabled:
        Keyword.get(opts, :enabled, Application.get_env(:commonplace, :trust_audit_enabled, true)),
      store: Keyword.get(opts, :store, CommitStoreClient),
      flush_ms: Keyword.get(opts, :flush_ms, @default_flush_ms),
      max_queue: Keyword.get(opts, :max_queue, @max_queue),
      task_supervisor: Keyword.get(opts, :task_supervisor, Commonplace.Trust.AuditTaskSupervisor),
      signing_context_fn: Keyword.get(opts, :signing_context_fn, &NodeIdentity.signing_context/0),
      boot_id: Keyword.get(opts, :boot_id, Commonplace.Trust.DenialCounter.boot_id()),
      # CX-m0qw review: the denial counter is :persistent_term and survives a
      # dispatcher restart; THESE counters do not. Without this baseline a
      # restart makes `emitted - offered` report every pre-restart denial as
      # fresh upstream loss, and the identity still balances, so the false
      # alarm is indistinguishable from a real one. Snapshot what the
      # denominator had already counted when this instance began.
      emitted_at_start: Commonplace.Trust.DenialCounter.value(),
      queue: :queue.new(),
      queued: 0,
      timer: nil,
      task: nil,
      in_flight: 0,
      offered: 0,
      recorded: 0,
      shed: 0,
      failed: 0,
      guarded: 0,
      waiters: []
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:audit, record}, state) do
    state = %{state | offered: state.offered + 1}

    cond do
      not state.enabled ->
        {:noreply, shed(state, record, :disabled)}

      state.queued >= state.max_queue ->
        {:noreply, shed(state, record, :queue_full)}

      true ->
        state = %{state | queue: :queue.in(record, state.queue), queued: state.queued + 1}
        {:noreply, arm(state)}
    end
  end

  # The recursion guard fires at the AuditLog entry, but the counter
  # lives here so `status/0` is the single denominator surface.
  def handle_cast({:guarded, _record}, state) do
    {:noreply, %{state | offered: state.offered + 1, guarded: state.guarded + 1}}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       store: state.store,
       boot_id: state.boot_id,
       emitted_at_start: state.emitted_at_start,
       offered: state.offered,
       recorded: state.recorded,
       shed: state.shed,
       failed: state.failed,
       guarded: state.guarded,
       queued: state.queued,
       in_flight: state.in_flight,
       max_queue: state.max_queue
     }, state}
  end

  def handle_call(:flush, from, state) do
    if state.queued == 0 and state.task == nil do
      {:reply, :ok, state}
    else
      state = %{state | waiters: [from | state.waiters]}
      {:noreply, arm(state, 0)}
    end
  end

  @impl true
  def handle_info(:flush_timer, state) do
    state = %{state | timer: nil}

    cond do
      state.task != nil -> {:noreply, state}
      state.queued == 0 -> {:noreply, maybe_reply_waiters(state)}
      true -> {:noreply, start_drain(state)}
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    batch_size = state.in_flight
    state = %{state | task: nil, in_flight: 0}

    state =
      case result do
        {:ok, n} ->
          :telemetry.execute(
            [:commonplace, :trust, :audit, :recorded],
            %{count: n},
            %{boot_id: state.boot_id}
          )

          %{state | recorded: state.recorded + n}

        {:error, reason} ->
          # LOUD. A failed audit persist is a security-observability
          # incident, not a retryable nuisance — and it is NOT retried
          # here on purpose: a retry loop against a gate that is
          # refusing the write is an amplifier, and the local Logger
          # line below is the fallback sink the brief requires.
          Logger.error(
            "Commonplace.Trust.AuditDispatcher: FAILED to persist #{batch_size} denial " <>
              "audit record(s) — denials are still being ENFORCED but are no longer being " <>
              "RECORDED in the substrate. reason=#{inspect(reason)}"
          )

          :telemetry.execute(
            [:commonplace, :trust, :audit, :persist_failed],
            %{count: batch_size},
            %{reason: reason, boot_id: state.boot_id}
          )

          %{state | failed: state.failed + batch_size}
      end

    state = if state.queued > 0, do: arm(state, 0), else: state
    {:noreply, maybe_reply_waiters(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    batch_size = state.in_flight

    Logger.error(
      "Commonplace.Trust.AuditDispatcher: persist task CRASHED, losing #{batch_size} " <>
        "denial audit record(s): #{inspect(reason)}"
    )

    state = %{state | task: nil, in_flight: 0, failed: state.failed + batch_size}
    state = if state.queued > 0, do: arm(state, 0), else: state
    {:noreply, maybe_reply_waiters(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── internals ────────────────────────────────────────────────────────

  defp shed(state, record, reason) do
    total = state.shed + 1

    # LOUD, but not an amplifier. The counter and the telemetry event
    # fire on EVERY shed — those are the machine-readable surfaces and
    # they must never miss one. The human-readable Logger line is
    # emitted on the first shed and then at decade boundaries, because a
    # denial flood turning into a log flood is how the shedding gets
    # scrolled past instead of noticed. The line always carries the
    # RUNNING TOTAL, so no decade is silent about its size.
    if log_shed?(total) do
      Logger.warning(
        "Commonplace.Trust.AuditDispatcher: SHED a denial audit record (#{reason}) — " <>
          "this node's denial audit trail is now known-incomplete. " <>
          "shed_total=#{total} queue=#{state.queued}/#{state.max_queue} " <>
          "record=#{inspect(Map.take(record, ["event", "doc_uuid", "reason"]))}"
      )
    end

    :telemetry.execute(
      [:commonplace, :trust, :audit, :shed],
      %{count: 1, shed_total: state.shed + 1},
      %{reason: reason, boot_id: state.boot_id}
    )

    %{state | shed: total}
  end

  defp log_shed?(1), do: true
  defp log_shed?(n) when n < 10, do: false
  defp log_shed?(n), do: rem(n, decade(n)) == 0

  defp decade(n), do: trunc(:math.pow(10, trunc(:math.log10(n))))

  defp arm(state, ms \\ nil)
  defp arm(%{timer: timer} = state, _ms) when timer != nil, do: state

  defp arm(state, ms) do
    %{state | timer: Process.send_after(self(), :flush_timer, ms || state.flush_ms)}
  end

  defp maybe_reply_waiters(%{queued: 0, task: nil, waiters: [_ | _] = waiters} = state) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    %{state | waiters: []}
  end

  defp maybe_reply_waiters(%{waiters: [_ | _]} = state), do: arm(state, 0)
  defp maybe_reply_waiters(state), do: state

  defp start_drain(state) do
    {batch, queue} = take(state.queue, @max_batch, [])
    n = length(batch)

    store = state.store
    ctx_fn = state.signing_context_fn
    boot_id = state.boot_id

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        persist_batch(store, ctx_fn, boot_id, batch)
      end)

    %{state | queue: queue, queued: state.queued - n, task: task, in_flight: n}
  end

  defp take(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp take(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> take(rest, n - 1, [item | acc])
      {:empty, rest} -> {Enum.reverse(acc), rest}
    end
  end

  # Runs in the TASK, never in this GenServer and — the whole point —
  # never in CommitStore's. `create_chained_commit` from here is an
  # ordinary cross-process call.
  @doc false
  def persist_batch(_store, _ctx_fn, _boot_id, []), do: {:ok, 0}

  def persist_batch(store, ctx_fn, boot_id, batch) do
    case signing_context(ctx_fn) do
      {:ok, ctx} ->
        log = RedLog.load(Commonplace.Trust.AuditLog.log_uuid(), store)

        log =
          Enum.reduce(batch, log, fn record, acc ->
            RedLog.append_raw(acc, Map.put(record, "boot_id", boot_id))
          end)

        case RedLog.commit(log, signing_context: ctx) do
          {:ok, _} -> {:ok, length(batch)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        # Refusing to write the record UNSIGNED is deliberate. An
        # unsigned audit write is refused by the gate under
        # `accept_unsigned: false` (CX-oc30, measured) — writing it
        # anyway would trade a counted failure for an uncounted one.
        {:error, {:no_node_signing_context, reason}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp signing_context(ctx_fn) do
    case ctx_fn.() do
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_signing_context, other}}
    end
  end
end
