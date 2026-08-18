defmodule Commonplace.Trust.AuditLog do
  @moduledoc """
  Durable audit trail for trust-decision events (CX-hilo, rebuilt by
  CX-t3xv).

  ## The gap this closes

  `Commonplace.Trust` and its callers emit telemetry on every rejected
  write, ignored revocation, and (in `:dry_run`) refused read:

    * `[:commonplace, :commit, :rejected, :local_trust]` — `commit_store.ex`, local write gate
    * `[:commonplace, :commit, :rejected, :trust]` — `commit_store.ex`, Gate A (import)
    * `[:commonplace, :trust, :revocation, :ignored]` — `trust/verify_chain.ex`
    * `[:commonplace, :trust, :read, :would_refuse]` — `trust/read.ex`

  `:telemetry.execute/3` is fire-and-forget: absent a handler, these
  events vanish. This module attaches a handler for all of them at app
  boot and hands each record to `Commonplace.Trust.AuditDispatcher`,
  which persists it — **out of band** — into
  `Commonplace.Dataflow.RedLog`.

  ## ENFORCEMENT NEVER STOPPED WORKING — only the RECORD did

  This subsystem is observability, and the distinction matters every
  time it is discussed. Three separate layers, none of which stands in
  for another:

    1. **gate enforcement** — denials deny. This was never broken, at
       any point, by either defect below.
    2. **audit persistence** — the record of the denial. This is what
       CX-t3xv and CX-oc30 killed, and what this module rebuilds.
    3. **telemetry capture in tests** — whether a test's ad-hoc handler
       receives the event it expects. A racing capture test says
       nothing about layer 2.

  ## What killed the previous build (both hands)

  Etiology verdict: **never-true**, not drift. Measured in
  `Commonplace.Trust.AuditEnforceEtiologyTest`.

  **Hand 1 (CX-t3xv), the self-call.** Telemetry handlers run in the
  process that fired the event. `handle_local_write_denial/3` fires from
  inside `CommitStore.handle_call`, so the old inline `persist/2` did
  `GenServer.call` into the CommitStore that was already inside its own
  `handle_call` → `:calling_self` **exit**. The handler's `rescue`
  could not see it (an exit is not an exception), `:telemetry` caught it
  as `Class=:exit`, and its crash policy **permanently detached this
  handler**. First denial on a node ⇒ no denial auditing until restart.

  **Hand 2 (CX-oc30), the unsigned audit write.** `RedLog.commit/1`
  passed no `:signing_context`, so the audit write was unsigned, so
  under `accept_unsigned: false` the local write gate refused it:
  auditing a denial was itself a denial. Independent of hand 1 — fixing
  either alone leaves the subsystem dead by the other.

  Both are addressed here and in `AuditDispatcher`, and BOTH have
  restore-the-bug controls (`AuditDualMechanismTest`) proving the
  acceptance check goes red if either is reintroduced.

  ## Placement

  The handler now does only what is free: build a map, check the
  recursion guard, check the rate gate, `cast`. Everything else happens
  in `AuditDispatcher` and its task. See that module for the queue
  bound, the loss counter, the denominator rule, and the parity probe.

  ## Recursion

  An audit record is a write, and a write can be denied, and a denied
  write fires the event this handler handles. `recursion_guard/1` cuts
  the loop at the entry: an event whose subject doc is `log_uuid/0` is
  never enqueued. It goes to the local `Logger` — a sink outside the
  substrate, therefore outside the loop — and increments the `guarded`
  counter so the suppression is visible rather than silent.

  ## The record: hash, never payload (brief §3)

  A denial record carries the timestamp, the denied principal (advisory
  — a `signer_id` is what the commit CLAIMED), the target doc, which
  check refused, the enforcement mode, a cert-chain summary (ids, not
  certs), and **a hash and byte size of the refused content — never the
  content itself.**

  Persisting the refused bytes would launder them into the store
  through their own refusal record: the write is denied, and then the
  denial writes it anyway. `content_digest/1` is the only thing that
  ever touches `commit.update`, and `AuditRecordShapeTest` pins that no
  record field can carry raw update bytes.

  ## Where the events land

  A single deterministically-derived red log doc UUID (`log_uuid/0`),
  the "stable UUID from a fixed seed" idiom
  `Commonplace.Presence.Mailbox.log_uuid_for_identity/1` uses. Tail it
  with the MCP `tail_red` tool, or
  `Commonplace.Dataflow.RedLog.load(Commonplace.Trust.AuditLog.log_uuid())
  |> Commonplace.Dataflow.RedLog.read()`.

  ## Flood guard

  `[:commonplace, :trust, :read, :would_refuse]` fires on every refused
  read while `:local_read_gate` is `:dry_run` — a citizen polling a
  denied resource in a loop could emit hundreds a second. Each event
  `{event_name, doc_uuid}` gets its own fixed-window bucket: at most 20
  records per 60-second window. The emitting process atomically increments a
  public ETS counter; it never waits for the supervised owner. The owner
  sweeps expired rows and writes a truthful summary (`"driven"`, `"admitted"`,
  and `"suppressed"`) through the dispatcher without requiring a later event
  and without passing through this admission gate. A storm on one document
  therefore cannot starve an independent document, and suppression is bounded
  volume rather than a silent zero. See `AuditRateLimiter` for lifecycle and
  the one-window hard-kill exposure bound.
  """

  require Logger

  alias Commonplace.Trust.{AuditDispatcher, AuditLogCounter, AuditRateLimiter}

  @handler_id "commonplace-trust-audit-log"

  # The audited deny sites. This list and
  # `Commonplace.Trust.DenySites.audited/0` are asserted equal by
  # `DenySiteScanTest` — a registry that claims coverage the handler
  # does not subscribe to would be a check that cannot fail.
  @events [
    [:commonplace, :commit, :rejected, :local_trust],
    [:commonplace, :commit, :rejected, :trust],
    [:commonplace, :commit, :rejected, :code_doc_delta_merge],
    [:commonplace, :code, :rejected, :trust],
    [:commonplace, :code, :rejected, :unsafe_verb],
    [:commonplace, :process, :rejected, :trust],
    [:commonplace, :federation, :rejected, :auth],
    [:commonplace, :trust, :revocation, :ignored],
    [:commonplace, :trust, :read, :would_refuse],
    # (b) verify-at-serve (0bf50a30): a last-good engine module whose CODE was
    # redefined since it was remembered is REFUSED and the floor served. A
    # refusal of substituted code is a security audit record, not diagnostics.
    [:commonplace, :mud, :engine_module, :md5_refused]
  ]

  @doc "The telemetry events this module audits."
  def events, do: @events

  @doc "The telemetry handler id."
  def handler_id, do: @handler_id

  @doc """
  Return all six `handle_event/4` stage counters for this BEAM boot.

  `offered` counts calls to `AuditDispatcher.offer/2` (records); the other
  fields count input events. The returned `boot_id` encloses every count.
  """
  @spec counters() :: map()
  def counters, do: AuditLogCounter.snapshot()

  @doc false
  def rate_cap, do: AuditRateLimiter.cap()

  @doc "The deterministic red-log doc UUID this module writes into."
  def log_uuid do
    UUID.uuid5(:url, "urn:commonplace:trust-audit-log")
  end

  @doc """
  Attach the audit handler. Idempotent — safe to call repeatedly (e.g.
  across app restarts in the same BEAM instance, or from tests), same
  detach/attach idiom `Commonplace.Reflog.Snapshot`'s dirty-tracker uses
  in `Commonplace.Application`.

  `opts[:dispatcher]` names the `AuditDispatcher` to feed (default
  `AuditDispatcher`). The `store` argument is retained for source
  compatibility and is carried in the handler config for diagnostics;
  the dispatcher owns the actual store handle, because the store a
  record is written to must not be decided inside the emitting process.
  """
  def attach(store \\ Commonplace.Store.CommitStoreClient, opts \\ []) do
    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @events,
      &__MODULE__.handle_event/4,
      %{store: store, dispatcher: Keyword.get(opts, :dispatcher, AuditDispatcher)}
    )
  end

  @doc "Detach the audit handler."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc """
  Whether the handler is currently attached. The deadman canary's
  cheapest precondition, and the thing whose silent falsification was
  the entire CX-t3xv defect.
  """
  @spec attached?() :: boolean()
  def attached? do
    Enum.any?(:telemetry.list_handlers([]), &(&1.id == @handler_id))
  end

  @doc false
  def handle_event(event_name, measurements, metadata, config) do
    AuditLogCounter.increment(:entered)
    dispatcher = Map.get(config, :dispatcher, AuditDispatcher)
    payload = build_payload(event_name, measurements, metadata)
    AuditLogCounter.increment(:built)

    cond do
      recursion_guard(payload) ->
        AuditLogCounter.increment(:guarded)
        # The fallback sink of last resort: the local Logger, which is
        # outside the substrate and therefore outside the loop. NEVER
        # re-enter the audit write path from here.
        Logger.error(
          "Commonplace.Trust.AuditLog: RECURSION GUARD — a denial of the AUDIT LOG's own " <>
            "doc (#{log_uuid()}) was not enqueued for auditing (that would loop). This means " <>
            "audit writes are themselves being refused: denial auditing is DEGRADED. " <>
            "record=#{inspect(Map.take(payload, ["event", "reason", "mode", "signer_id"]))}"
        )

        GenServer.cast(dispatcher, {:guarded, payload})

      true ->
        case rate_gate(event_name, payload, dispatcher) do
          :log ->
            # `offer_events` counts EVENTS reaching this stage; `offered` counts
            # RECORDS handed to the dispatcher. The timer owner also increments
            # `offered` for summaries without inventing an input event, so only
            # `offer_events` belongs in the stage identity. See AuditLogCounter.
            AuditLogCounter.increment(:offer_events)
            AuditLogCounter.increment(:offered)
            AuditDispatcher.offer(dispatcher, payload)

          :suppress ->
            AuditLogCounter.increment(:rate_suppressed)
            :ok
        end
    end

    :ok
  rescue
    error ->
      handler_failure({:raised, error}, __STACKTRACE__)
  catch
    # ** THE CX-t3xv LESSON, IN THE CODE THAT LEARNED IT **
    #
    # `rescue` alone does NOT catch exits, and the defect that killed
    # this subsystem was an exit (`:calling_self`). An uncaught throw or
    # exit here is caught by `:telemetry`, which then PERMANENTLY
    # DETACHES this handler — turning any transient fault in a security
    # observability surface into a permanent, silent one. For a security
    # surface, detach-on-first-crash is the wrong policy, so this handler
    # takes responsibility for never crashing.
    kind, value ->
      handler_failure({kind, value}, __STACKTRACE__)
  end

  @doc """
  True when this payload describes a denial OF the audit log's own doc.

  Public because the recursion hazard is a property of the SYSTEM, not
  of this function, and the test that proves the loop is cut asserts on
  it by name.
  """
  @spec recursion_guard(map()) :: boolean()
  def recursion_guard(%{"doc_uuid" => doc_uuid}), do: doc_uuid == log_uuid()
  def recursion_guard(_), do: false

  defp handler_failure(reason, stacktrace) do
    AuditLogCounter.increment(:handler_failed)

    Logger.error(
      "Commonplace.Trust.AuditLog: handler failed (#{inspect(reason)}) — SWALLOWED so " <>
        ":telemetry does not detach it. Denial auditing may have lost this record; " <>
        "enforcement is unaffected. " <> Exception.format_stacktrace(stacktrace)
    )

    :telemetry.execute(
      [:commonplace, :trust, :audit, :handler_error],
      %{count: 1},
      %{reason: inspect(reason)}
    )

    :ok
  end

  # --- payload shaping (brief §3) ---

  defp build_payload(
         [:commonplace, :commit, :rejected, :local_trust] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "gate" => "local_write",
      "doc_uuid" => Map.get(metadata, :doc_uuid),
      "commit_id" => encode_id(Map.get(metadata, :commit_id)),
      "mode" => Map.get(metadata, :mode),
      # Advisory: a signer_id is what the commit CLAIMED, and on the
      # unsigned path it is nil precisely because the claim was absent.
      "signer_id_claimed" => encode_id(Map.get(metadata, :signer_id)),
      "writer" => writer_payload(metadata),
      "check" => check_name(Map.get(metadata, :reason)),
      "reason" => inspect(Map.get(metadata, :reason)),
      "cert_chain" => cert_summary(Map.get(metadata, :cert_cids)),
      "system_time" => Map.get(measurements, :system_time)
    }
    |> Map.merge(Map.get(metadata, :content_digest) || %{})
    |> Map.put("firing_process", firing_process())
  end

  defp build_payload(
         [:commonplace, :commit, :rejected, :trust] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "gate" => "import",
      "doc_uuid" => Map.get(metadata, :doc_uuid),
      "commit_id" => encode_id(Map.get(metadata, :commit_id)),
      "mode" => "enforce",
      "signer_id_claimed" => encode_id(Map.get(metadata, :signer_id)),
      "check" => check_name(Map.get(metadata, :reason)),
      "reason" => inspect(Map.get(metadata, :reason)),
      "cert_chain" => cert_summary(Map.get(metadata, :cert_cids)),
      "system_time" => Map.get(measurements, :system_time)
    }
    |> Map.merge(Map.get(metadata, :content_digest) || %{})
    |> Map.put("firing_process", firing_process())
  end

  # Gate B / sandbox_exec / safe-verb / code-doc-merge / federation.
  #
  # One clause on purpose. These sites differ in what they refuse, not
  # in what an operator needs to see, and a per-site clause is how a
  # future site gets forgotten. The generic shape carries whatever
  # subject and principal keys the site supplies and records WHICH check
  # refused, which is the record's real payload (brief §3).
  defp build_payload([:commonplace, area, :rejected, kind] = event_name, measurements, metadata) do
    %{
      "event" => Enum.join(event_name, "."),
      "gate" => "#{area}.#{kind}",
      "doc_uuid" => Map.get(metadata, :doc_uuid) || Map.get(metadata, :uuid),
      "dir_uuid" => Map.get(metadata, :dir_uuid),
      "commit_id" => encode_id(Map.get(metadata, :commit_id)),
      "mode" => Map.get(metadata, :mode),
      "principal" => Map.get(metadata, :principal) || Map.get(metadata, :peer),
      "signer_id_claimed" => encode_id(Map.get(metadata, :signer_id)),
      "check" => check_name(Map.get(metadata, :reason)),
      "reason" => inspect(Map.get(metadata, :reason)),
      "cert_chain" => cert_summary(Map.get(metadata, :cert_cids)),
      "system_time" => Map.get(measurements, :system_time) || System.system_time()
    }
    |> Map.merge(Map.get(metadata, :content_digest) || %{})
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Map.put("firing_process", firing_process())
  end

  defp build_payload(
         [:commonplace, :trust, :revocation, :ignored] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "gate" => "revocation",
      "check" => "revocation_ignored",
      "cap_id" => encode_id(Map.get(metadata, :cap_id)),
      "revoker_pubkey" => encode_id(Map.get(metadata, :revoker_pubkey)),
      "system_time" => Map.get(measurements, :system_time)
    }
    |> Map.put("firing_process", firing_process())
  end

  defp build_payload(
         [:commonplace, :trust, :read, :would_refuse] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "gate" => "local_read",
      "check" => "read_visibility",
      "doc_uuid" => Map.get(metadata, :target),
      "reader" => Map.get(metadata, :reader),
      "surface" => Map.get(metadata, :surface),
      "visibility" => Map.get(metadata, :visibility),
      "count" => Map.get(measurements, :count, 1)
    }
    |> Map.put("firing_process", firing_process())
  end

  # (b) verify-at-serve (mechanism proof: 0bf50a30): the last-good engine-module
  # cache refused an atom whose code was redefined since it was remembered.
  # Substituted code was NOT served; the compiled-in floor was.
  defp build_payload(
         [:commonplace, :mud, :engine_module, :md5_refused] = event_name,
         measurements,
         metadata
       ) do
    %{
      "event" => Enum.join(event_name, "."),
      "gate" => "engine_module_last_good",
      "check" => "code_identity",
      "doc_uuid" => Map.get(metadata, :uuid),
      "engine_name" => inspect(Map.get(metadata, :name)),
      "count" => Map.get(measurements, :count, 1)
    }
    |> Map.put("firing_process", firing_process())
  end

  # Backstop. An event added to `@events` without a shaping clause would
  # otherwise raise FunctionClauseError inside the handler — which the
  # `rescue` would swallow, turning a wiring mistake into a silently
  # unaudited deny site. Recording a coarse record and saying so is
  # strictly better than recording nothing quietly.
  defp build_payload(event_name, measurements, metadata) do
    Logger.warning(
      "Commonplace.Trust.AuditLog: no payload shaper for #{inspect(event_name)} — " <>
        "recording a coarse record. Add a build_payload/3 clause."
    )

    %{
      "event" => Enum.join(event_name, "."),
      "gate" => "unshaped",
      "check" => "unshaped",
      "doc_uuid" => Map.get(metadata, :doc_uuid),
      "reason" => inspect(Map.drop(metadata, [:content_digest])),
      "system_time" => Map.get(measurements, :system_time) || System.system_time()
    }
    |> Map.put("firing_process", firing_process())
  end

  defp writer_payload(metadata) do
    case Map.fetch(metadata, :writer) do
      :error -> %{"status" => "not_provided"}
      {:ok, nil} -> %{"status" => "absent"}
      {:ok, writer} -> writer
    end
  end

  defp firing_process do
    registered_name =
      case Process.info(self(), :registered_name) do
        {:registered_name, name} when is_atom(name) -> Atom.to_string(name)
        {:registered_name, []} -> "unnamed"
      end

    %{"registered_name" => registered_name, "pid" => inspect(self())}
  end

  @doc """
  The ONLY function permitted to touch a refused commit's bytes.

  Returns shape and hash — `%{"content_sha256" => hex, "content_bytes" => n}`
  — and never the bytes. A denial record that persisted the refused
  payload would launder it into the store through its own refusal.
  """
  @spec content_digest(binary() | nil) :: map()
  def content_digest(update) when is_binary(update) do
    %{
      "content_sha256" => :crypto.hash(:sha256, update) |> Base.encode16(case: :lower),
      "content_bytes" => byte_size(update)
    }
  end

  def content_digest(_), do: %{}

  # Which check refused — the record's actionable payload (brief §3).
  defp check_name(:unsigned), do: "signature_absent"
  defp check_name(:invalid_signer_id), do: "signer_id_malformed"
  defp check_name(:bad_signature), do: "signature_invalid"
  defp check_name({:untrusted_signer, _}), do: "signer_untrusted"
  defp check_name(:awaiting_capability), do: "cert_chain_incomplete"
  defp check_name({:capability, _}), do: "cert_chain"
  defp check_name(:capability_insufficient), do: "scope"
  defp check_name(other) when is_atom(other), do: Atom.to_string(other)
  defp check_name({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp check_name(_), do: "unclassified"

  # Cert-chain SUMMARY: issuer/cert ids, never the certs themselves.
  defp cert_summary(nil), do: []

  defp cert_summary(cids) when is_list(cids) do
    Enum.map(cids, &encode_id/1)
  end

  defp cert_summary(other), do: [encode_id(other)]

  defp encode_id(id) when is_binary(id) do
    if String.printable?(id), do: id, else: Base.encode16(id, case: :lower)
  end

  defp encode_id(other), do: other

  # --- flood guard: per-{event-name, doc} bucket + out-of-band summary ---

  @doc false
  # Test support: the rate table is global, named, and shared across the
  # whole BEAM run, so any test that asserts on dispatcher offers must
  # start from a fresh bucket or inherit whatever the suite ran before it
  # (that inheritance was a red CI on the first post-merge run). This is
  # the ONE sanctioned way to clear it — tests must not reach into the
  # named table themselves.
  def reset_rate_table do
    table = AuditRateLimiter.table()
    if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    :ok
  end

  defp rate_gate(event_name, payload, dispatcher) do
    AuditRateLimiter.admit(event_name, Map.get(payload, "doc_uuid"), dispatcher)
  end
end
