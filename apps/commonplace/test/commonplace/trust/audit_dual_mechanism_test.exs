defmodule Commonplace.Trust.AuditDualMechanismTest do
  @moduledoc """
  CX-t3xv acceptance criterion 1 + **boss's binding rider**.

  ## The rider, and why single-fix verification is worthless here

  Denial auditing had TWO independent kill mechanisms:

    * **CX-t3xv** — the audit persist ran inside `CommitStore`'s own
      `handle_call`, so it `GenServer.call`ed itself, exited
      `:calling_self`, and `:telemetry` permanently detached the handler.
    * **CX-oc30** — the audit write was unsigned, so under
      `accept_unsigned: false` the local write gate refused it. Auditing
      a denial was itself a denial.

  Either one alone kills the subsystem. So "denials now appear in the
  log" can be **true-for-one-reason while false-for-the-other**, and a
  green check that only ever exercised one mechanism proves nothing.

  Acceptance is therefore: a denial demonstrably RECORDED with BOTH
  mechanisms fixed in the SAME run, **plus controls proving the check
  goes red if EITHER is reintroduced** — the restore-the-bug technique,
  applied twice.

  ## ENFORCEMENT NEVER STOPPED WORKING — only the RECORD did

  Every test here asserts the denial FIRST (`{:error, {:trust_rejected,
  _}}`, nothing persisted) and the record SECOND. In every red control
  below, the denial still denies; only the record disappears. Three
  layers, none standing in for another:

    1. **gate enforcement** — never broken, by either defect.
    2. **audit persistence** — what was dead; what is fixed here.
    3. **telemetry capture in tests** — a racing `assert_receive` in a
       neighbour test says nothing about layer 2.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.{AuditDispatcher, AuditLog}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_audit_dual_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"adm_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"adm_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"adm_tss_#{n}",
       pending_imports_name: :"adm_pi_#{n}"}
    )

    old = %{
      gate: Application.get_env(:commonplace, :local_write_gate),
      trust: Application.get_env(:commonplace, :trust),
      data_dir: Application.get_env(:commonplace, :data_dir)
    }

    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      AuditLog.detach()
      Enum.each(old, fn {k, v} -> restore(k, v) end)
      File.rm_rf!(dir)
    end)

    AuditLog.reset_rate_table()

    %{store: store, n: n, dir: dir}
  end

  defp restore(:gate, v), do: put_or_del(:local_write_gate, v)
  defp restore(:trust, v), do: put_or_del(:trust, v)
  defp restore(:data_dir, v), do: put_or_del(:data_dir, v)

  defp put_or_del(key, nil), do: Application.delete_env(:commonplace, key)
  defp put_or_del(key, v), do: Application.put_env(:commonplace, key, v)

  defp strict_enforce! do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)
  end

  defp text_update(body) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "page.md")
    |> ContentType.insert_text(0, body)
    |> Yelixer.Encoding.encode_update()
  end

  # Start a dispatcher. `opts` lets a red control reintroduce a bug.
  defp start_dispatcher!(store, n, opts \\ []) do
    sup = :"adm_tasks_#{n}_#{:rand.uniform(1_000_000)}"
    name = :"adm_disp_#{n}_#{:rand.uniform(1_000_000)}"
    start_supervised!({Task.Supervisor, name: sup}, id: sup)

    start_supervised!(
      {AuditDispatcher,
       [name: name, store: store, task_supervisor: sup, flush_ms: 10, enabled: true] ++ opts},
      id: name
    )

    name
  end

  # ── the acceptance check, as ONE function ────────────────────────────
  #
  # Written once and reused by the green case and both red controls.
  # If the green case and the controls ran DIFFERENT checks, the controls
  # would prove nothing about the check that actually gates acceptance.
  #
  # Returns `{:ok, record}` or `{:error, why}` — never raises, so a
  # control can assert on the failure shape instead of on an exception.
  defp acceptance_check(store, dispatcher) do
    uuid = UUID.uuid4()

    # LAYER 1 — enforcement. Asserted, not assumed.
    with {:error, {:trust_rejected, :unsigned}} <-
           CommitStore.create_commit(store, uuid, text_update("secret"), nil),
         :none <- CommitStore.latest_commit(store, uuid) do
      _ = AuditDispatcher.flush(dispatcher, 5_000)

      status = AuditDispatcher.status(dispatcher)

      records =
        AuditLog.log_uuid()
        |> RedLog.load(store)
        |> RedLog.read()

      # MECHANISM B — the substrate red-log doc.
      b_record = Enum.find(records, &(&1["doc_uuid"] == uuid))

      cond do
        # MECHANISM A — the in-band counter surface.
        not is_integer(status[:recorded]) or status.recorded < 1 ->
          {:error, {:mechanism_a_empty, status}}

        is_nil(b_record) ->
          {:error, {:mechanism_b_empty, status, length(records)}}

        not AuditLog.attached?() ->
          {:error, :handler_detached}

        true ->
          {:ok, b_record, status}
      end
    else
      other -> {:error, {:enforcement_changed, other}}
    end
  end

  # ── GREEN: both mechanisms fixed, in the SAME run ────────────────────

  test "a denial is RECORDED with both kill mechanisms fixed, in one run", %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n)
    AuditLog.attach(s, dispatcher: dispatcher)
    strict_enforce!()

    assert {:ok, record, status} = acceptance_check(s, dispatcher)

    # The record's shape is the operator's actual payload (brief §3).
    assert record["gate"] == "local_write"
    assert record["mode"] == "enforce"
    assert record["check"] == "signature_absent"
    assert record["reason"] =~ "unsigned"
    assert is_integer(record["content_bytes"])
    assert record["content_sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert is_binary(record["boot_id"])

    # Denominator rule: everything offered is accounted for.
    assert AuditDispatcher.downstream_accounted?(status),
           "audit counters do not sum: #{inspect(status)}"

    assert status.shed == 0
    assert status.failed == 0

    # Count parity: the two mechanisms agree.
    parity = AuditDispatcher.parity(dispatcher)
    assert parity.in_parity, "mechanisms disagree: #{inspect(parity)}"
  end

  # ── RED CONTROL 1: reintroduce CX-t3xv (the :calling_self detach) ────
  #
  # The bug restored FAITHFULLY: a handler that persists INLINE, in the
  # process that fired the event — which for the local write gate is
  # CommitStore's own `handle_call`. This is byte-for-byte the shape the
  # original `AuditLog.persist/2` had.
  test "RED CONTROL: reintroducing the inline (self-calling) persist kills the check",
       %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n)
    strict_enforce!()

    # The legacy handler, in place of the fixed one, under the same id.
    :telemetry.detach(AuditLog.handler_id())

    :ok =
      :telemetry.attach(
        AuditLog.handler_id(),
        [:commonplace, :commit, :rejected, :local_trust],
        &__MODULE__.legacy_inline_handler/4,
        %{store: s}
      )

    assert AuditLog.attached?(), "precondition: the legacy handler is attached"

    assert {:error, why} = acceptance_check(s, dispatcher)

    # It fails for the RIGHT reason: nothing recorded, and the handler is
    # gone — telemetry detached it after the :calling_self exit.
    assert match?({:mechanism_a_empty, _}, why) or match?({:mechanism_b_empty, _, _}, why),
           "expected an empty-mechanism failure, got #{inspect(why)}"

    refute AuditLog.attached?(),
           "the restored bug should have caused telemetry to DETACH the handler — " <>
             "if it did not, this control is not reproducing CX-t3xv"
  end

  @doc false
  # Verbatim the pre-CX-t3xv persist path: load + append + commit,
  # synchronously, in the caller's process.
  def legacy_inline_handler(_event, _meas, metadata, %{store: store}) do
    log = RedLog.load(AuditLog.log_uuid(), store)
    log = RedLog.append_raw(log, %{"doc_uuid" => Map.get(metadata, :doc_uuid)})
    _ = RedLog.commit(log)
    :ok
  end

  # ── RED CONTROL 2: reintroduce CX-oc30 (unsigned audit writes) ───────
  #
  # Everything else stays fixed — async dispatch, exit-safe handler, the
  # whole architecture. ONLY the signing is reverted, by injecting a
  # signing context of `:unsigned` (the value `maybe_sign_commit/2` reads
  # as "deliberately do not sign"). The audit write is then refused by
  # the very gate whose denial it is trying to record.
  test "RED CONTROL: reintroducing unsigned audit writes kills the check", %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n, signing_context_fn: fn -> {:ok, :unsigned} end)
    AuditLog.attach(s, dispatcher: dispatcher)
    strict_enforce!()

    assert {:error, why} = acceptance_check(s, dispatcher)

    assert match?({:mechanism_b_empty, _, _}, why) or match?({:mechanism_a_empty, _}, why),
           "expected an empty-mechanism failure, got #{inspect(why)}"

    status = AuditDispatcher.status(dispatcher)

    # And it is LOUD: the failure is counted, not silent.
    assert status.failed > 0,
           "the refused audit write must be COUNTED as failed, not dropped silently: " <>
             inspect(status)

    assert AuditDispatcher.downstream_accounted?(status),
           "counters must still sum even when persistence fails: #{inspect(status)}"

    # Enforcement, meanwhile, is untouched.
    assert AuditLog.attached?(),
           "the handler must survive a refused audit write — only the RECORD is lost"
  end

  # ── RED CONTROL 3: the node-signing dependency, stated ───────────────
  #
  # If the node identity cannot be sourced, the record is NOT written
  # unsigned and hoped for. It is counted as failed and logged, because
  # a write that will be refused is not an audit trail.
  test "RED CONTROL: no node signing context => counted failure, never a silent unsigned write",
       %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n, signing_context_fn: fn -> {:error, :no_node_key} end)
    AuditLog.attach(s, dispatcher: dispatcher)
    strict_enforce!()

    assert {:error, _} = acceptance_check(s, dispatcher)

    status = AuditDispatcher.status(dispatcher)
    assert status.failed > 0
    assert status.recorded == 0
  end

  # ── AC1: more than one deny-site CLASS ───────────────────────────────

  test "Gate A (import) denials are audited too, not just the local write gate",
       %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n)
    AuditLog.attach(s, dispatcher: dispatcher)
    strict_enforce!()

    uuid = UUID.uuid4()

    # Properly content-addressed and UNSIGNED: the id/integrity checks
    # run BEFORE trust, so a hand-forged id would be refused by
    # `:id_mismatch` (an exempt, non-trust deny site) and this test would
    # be measuring the wrong refusal entirely.
    commit = Commit.new(uuid, text_update("from a peer"), nil)

    # LAYER 1: Gate A always verifies, regardless of the local knob.
    assert {:error, {:trust_rejected, _}} = CommitStore.import_commit(s, commit)

    _ = AuditDispatcher.flush(dispatcher, 5_000)

    records = AuditLog.log_uuid() |> RedLog.load(s) |> RedLog.read()

    assert Enum.any?(records, &(&1["gate"] == "import" and &1["doc_uuid"] == uuid)),
           "Gate A denial unaudited. records=#{inspect(records)}"
  end

  test "every audited deny-site class produces a shaped record", %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n)
    AuditLog.attach(s, dispatcher: dispatcher)
    strict_enforce!()

    # The remaining classes are emitted from modules whose real
    # invocation needs a MUD world / a sandbox / a Plug conn. They are
    # exercised here at the EVENT level, which is the seam this
    # subsystem actually consumes — and stated plainly rather than
    # claimed as an end-to-end.
    for event <- AuditLog.events() do
      :telemetry.execute(event, %{system_time: System.system_time()}, %{
        doc_uuid: UUID.uuid4(),
        target: UUID.uuid4(),
        reason: :unsigned
      })
    end

    _ = AuditDispatcher.flush(dispatcher, 5_000)

    records = AuditLog.log_uuid() |> RedLog.load(s) |> RedLog.read()
    gates = records |> Enum.map(& &1["gate"]) |> Enum.uniq()

    # Never a bare count: report which classes landed.
    assert length(records) >= length(AuditLog.events()),
           "expected >= #{length(AuditLog.events())} records, got #{length(records)}; " <>
             "gates seen: #{inspect(gates)}"

    refute "unshaped" in gates,
           "an audited event has no payload shaper — gates seen: #{inspect(gates)}"
  end

  # ── Recursion: cut, counted, never looped ────────────────────────────

  test "a denial OF the audit doc is guarded, not enqueued, and never loops",
       %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n)
    AuditLog.attach(s, dispatcher: dispatcher)
    strict_enforce!()

    before = AuditDispatcher.status(dispatcher)

    # Exactly the event a refused audit write would fire.
    :telemetry.execute(
      [:commonplace, :commit, :rejected, :local_trust],
      %{system_time: System.system_time()},
      %{mode: :enforce, doc_uuid: AuditLog.log_uuid(), commit_id: <<1, 2, 3>>, reason: :unsigned}
    )

    _ = AuditDispatcher.flush(dispatcher, 5_000)
    after_ = AuditDispatcher.status(dispatcher)

    assert after_.guarded == before.guarded + 1,
           "the recursion guard must COUNT what it suppresses: #{inspect(after_)}"

    assert after_.recorded == before.recorded,
           "a denial of the audit doc must NOT be written into the audit doc"

    assert AuditDispatcher.downstream_accounted?(after_),
           "guarded events must appear in the denominator: #{inspect(after_)}"
  end

  # ── Hash, never payload ──────────────────────────────────────────────

  test "the refused bytes are never persisted — hash and size only", %{store: s, n: n} do
    dispatcher = start_dispatcher!(s, n)
    AuditLog.attach(s, dispatcher: dispatcher)
    strict_enforce!()

    marker = "TOPSECRET-#{:rand.uniform(1_000_000_000)}"
    update = text_update(marker)
    uuid = UUID.uuid4()

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.create_commit(s, uuid, update, nil)

    _ = AuditDispatcher.flush(dispatcher, 5_000)

    record = AuditLog.log_uuid() |> RedLog.load(s) |> RedLog.read() |> Enum.find(&(&1["doc_uuid"] == uuid))

    assert record, "precondition: the denial was recorded"

    # The whole record, serialized, must not contain the refused content.
    # A denial record that persists the refused payload launders those
    # bytes into the store through their own refusal.
    serialized = Jason.encode!(record)

    refute String.contains?(serialized, marker),
           "the refused CONTENT appears in the audit record: #{serialized}"

    assert record["content_sha256"] ==
             :crypto.hash(:sha256, update) |> Base.encode16(case: :lower)

    assert record["content_bytes"] == byte_size(update)
  end

  # ── AC7: "is it started" closed structurally ─────────────────────────

  # Asserted against the RUNNING tree, not against a list in the source.
  # "The starter is in application.ex" is a claim about a file; "the
  # process is alive under the app supervisor" is the fact the criterion
  # actually wants, and it is the one that would have gone red on every
  # boot where this subsystem was dormant.
  test "the auditor, its task supervisor, and its canary are ALIVE under the app" do
    for required <- [
          Commonplace.Trust.AuditDispatcher,
          Commonplace.Trust.AuditTaskSupervisor,
          Commonplace.Trust.AuditCanary
        ] do
      pid = Process.whereis(required)

      assert is_pid(pid) and Process.alive?(pid),
             "#{inspect(required)} is not running — 'is it started' would again be a review " <>
               "question rather than a running fact"
    end

    # And the dispatcher is answering, not merely alive.
    status = AuditDispatcher.status()
    assert is_integer(status.offered)
    assert AuditDispatcher.downstream_accounted?(status)
  end

  test "the audit handler is attached, subscribed to EVERY audited event" do
    # The suite detaches/re-attaches around other tests, so the load-
    # bearing assertion is that `attach/2` with app defaults produces a
    # handler subscribed to the full audited set — a handler attached to
    # a SUBSET is exactly how a deny site goes quietly unaudited.
    AuditLog.attach()
    assert AuditLog.attached?()

    subscribed =
      :telemetry.list_handlers([])
      |> Enum.filter(&(&1.id == AuditLog.handler_id()))
      |> Enum.map(& &1.event_name)
      |> MapSet.new()

    assert subscribed == MapSet.new(AuditLog.events())
  end

  # ── the DEFAULT wiring, with nothing injected ────────────────────────
  #
  # Every other test in this file builds its own dispatcher pointed at
  # its own store. That proves the design works; it does not prove the
  # DEPLOYED wiring works, and the deployed wiring is what was dead for
  # the whole life of the previous build. This test injects nothing: the
  # app-supervised dispatcher, the app-attached handler, the default
  # store.
  #
  # It is also the pin that keeps the CX-7m9g contamination fixed at the
  # source rather than at the assertion. Before this ticket, a denial
  # under enforce caused the audit log's OWN write to be refused, and
  # that second denial's telemetry (doc_uuid = the fixed audit uuid5)
  # leaked into neighbouring tests' captures. It cannot leak now because
  # it no longer happens: the audit write is node-signed and lands.
  test "the DEFAULT application wiring records a denial — nothing injected", %{dir: dir} do
    AuditLog.attach()
    dispatcher = AuditDispatcher

    before = AuditDispatcher.status(dispatcher)

    # The default store, not a test-local one.
    store = Commonplace.Store.CommitStoreClient
    uuid = UUID.uuid4()

    old_dd = Application.get_env(:commonplace, :data_dir)
    on_exit(fn -> if old_dd, do: Application.put_env(:commonplace, :data_dir, old_dd) end)
    _ = dir

    strict_enforce!()

    assert {:error, {:trust_rejected, _}} =
             Commonplace.Store.CommitStoreClient.create_chained_commit(
               store,
               uuid,
               text_update("secret")
             )

    assert :ok = AuditDispatcher.flush(dispatcher, 10_000)

    after_ = AuditDispatcher.status(dispatcher)

    assert after_.recorded > before.recorded,
           "the app-supervised dispatcher recorded nothing: #{inspect(after_)}"

    assert after_.failed == before.failed,
           "the app-supervised audit write FAILED — this is the CX-oc30 shape reappearing " <>
             "under the default wiring: #{inspect(after_)}"

    # And no denial of the audit doc itself occurred: the guard counter
    # did not move. A moving `guarded` here would mean audit writes are
    # being refused again, which is precisely the state that produced the
    # CX-7m9g cross-test contamination.
    assert after_.guarded == before.guarded,
           "the audit doc's own write was denied — CX-oc30 is back: #{inspect(after_)}"
  end
end
