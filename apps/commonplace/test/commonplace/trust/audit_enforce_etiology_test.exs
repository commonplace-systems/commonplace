defmodule Commonplace.Trust.AuditEnforceEtiologyTest do
  @moduledoc """
  CX-t3xv, step 0 — ETIOLOGY, not construction.

  The brief (`2026-08-06-cx-t3xv-denial-auditing-brief.md` §0) forbids
  building before naming the disease: **drift** (it worked, something
  broke it) or **never-true** (it never worked in the posture that
  matters). This file is the measurement, and it is deliberately written
  to be RED before the fix.

  ## Why the pre-existing `AuditLogTest` cannot answer this

  `Commonplace.Trust.AuditLogTest` fires `:telemetry.execute/3` from the
  TEST process, with the trust config left permissive and the
  `:local_write_gate` knob untouched. Both kill mechanisms are therefore
  structurally out of its reach:

    * the `:calling_self` deadlock needs the handler to run INSIDE
      `CommitStore`'s `handle_call` — telemetry handlers run in the
      caller's process, so firing from the test process runs the handler
      in the test process, where `GenServer.call` into the store is a
      perfectly ordinary cross-process call;
    * the unsigned-audit-write denial (CX-oc30) needs
      `accept_unsigned: false` + `local_write_gate: :enforce` — under the
      permissive default the audit log's own write is allowed.

  It is a green check that could not have gone red for either real
  cause: the `reference_checks_that_cannot_fail` pattern. This file
  supplies the missing posture on both axes.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Trust.AuditLog

  @handler_id "commonplace-trust-audit-log"

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_audit_etiology_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"ae_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"ae_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"ae_tss_#{n}",
       pending_imports_name: :"ae_pi_#{n}"}
    )

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)
    old_data_dir = Application.get_env(:commonplace, :data_dir)

    # The node signing identity is read out of `:data_dir`; give this
    # test its own so the node keypair is minted inside the temp dir and
    # never shared with a neighbour.
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      AuditLog.detach()
      restore(:local_write_gate, old_gate)
      restore(:trust, old_trust)
      restore(:data_dir, old_data_dir)
      File.rm_rf!(dir)
    end)

    AuditLog.reset_rate_table()

    # This test's own dispatcher, pointed at this test's own store. The
    # app-level dispatcher writes to the global CommitStoreClient, which
    # is not where this test's denials live.
    sup = :"ae_tasks_#{n}"
    dispatcher = :"ae_dispatch_#{n}"
    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {Commonplace.Trust.AuditDispatcher,
       name: dispatcher, store: name, task_supervisor: sup, flush_ms: 10, enabled: true}
    )

    %{store: name, dir: dir, dispatcher: dispatcher}
  end

  defp attach!(store, dispatcher), do: AuditLog.attach(store, dispatcher: dispatcher)

  defp settle(dispatcher) do
    Commonplace.Trust.AuditDispatcher.flush(dispatcher, 5_000)
  end

  defp restore(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore(key, v), do: Application.put_env(:commonplace, key, v)

  defp strict!, do: Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
  defp enforce!, do: Application.put_env(:commonplace, :local_write_gate, :enforce)

  defp text_update(body) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "page.md")
    doc = ContentType.insert_text(doc, 0, body)
    Yelixer.Encoding.encode_update(doc)
  end

  defp audit_records(store) do
    AuditLog.log_uuid() |> RedLog.load(store) |> RedLog.read()
  end

  defp handler_attached? do
    Enum.any?(:telemetry.list_handlers([]), &(&1.id == @handler_id))
  end

  # ── Etiology 1: does the handler survive the FIRST enforce denial? ────
  #
  # The ticket's measured mechanism: handler runs inside CommitStore's
  # handle_call, RedLog.load calls back into that same GenServer, the
  # call exits `:calling_self`, and telemetry's crash policy DETACHES the
  # handler permanently. If that is real, `handler_attached?` is false
  # after denial #1 and denial #2 is not even seen.
  test "the audit handler survives the first enforce-mode denial", %{store: store, dispatcher: d} do
    attach!(store, d)
    assert handler_attached?(), "precondition: handler attached before any denial"

    strict!()
    enforce!()

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.create_commit(store, UUID.uuid4(), text_update("one"), nil)

    assert handler_attached?(),
           "the audit handler was DETACHED by the first denial — all subsequent " <>
             "denial auditing on this node is dead until restart"
  end

  # ── Etiology 2: is a denial actually RECORDED under enforce? ─────────
  #
  # This is the property the whole subsystem exists for, asserted in the
  # posture it exists for. Independent of WHICH mechanism kills it.
  test "an enforce-mode denial is recorded in the substrate audit log", %{store: store, dispatcher: d} do
    attach!(store, d)
    strict!()
    enforce!()

    uuid = UUID.uuid4()

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.create_commit(store, uuid, text_update("secret"), nil)

    assert :ok = settle(d)

    records = audit_records(store)

    assert Enum.any?(records, &(&1["doc_uuid"] == uuid)),
           "no audit record for the denied write. records=#{inspect(records)}"
  end

  # ── Etiology 3: denial #2 must be audited too ────────────────────────
  #
  # The exact property the telemetry detach destroys, and the regression
  # pin the ticket names by hand.
  test "the SECOND enforce-mode denial is also recorded", %{store: store, dispatcher: d} do
    attach!(store, d)
    strict!()
    enforce!()

    first = UUID.uuid4()
    second = UUID.uuid4()

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.create_commit(store, first, text_update("one"), nil)

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.create_commit(store, second, text_update("two"), nil)

    assert :ok = settle(d)

    records = audit_records(store)
    logged = Enum.map(records, & &1["doc_uuid"])

    assert first in logged, "denial #1 unaudited. logged=#{inspect(logged)}"
    assert second in logged, "denial #2 unaudited (the detach signature). logged=#{inspect(logged)}"
  end

  # ── Etiology 4: CX-oc30's mechanism, isolated ────────────────────────
  #
  # Independent of the deadlock: is the audit log's OWN write allowed
  # under enforce? Written as a direct measurement so the verdict does
  # not depend on the deadlock being fixed first. An unsigned write to
  # the audit doc under strict+enforce is denied — auditing a denial is
  # itself a denial.
  test "MEASURE: an unsigned write to the audit doc is denied under enforce", %{store: store} do
    strict!()
    enforce!()

    result =
      CommitStoreClient.create_chained_commit(store, AuditLog.log_uuid(), text_update("audit"))

    assert {:error, {:trust_rejected, :unsigned}} = result
  end

  # ── Etiology 5: the node-signed control ──────────────────────────────
  #
  # The counterpart measurement that makes #4 actionable rather than
  # merely alarming: a NODE-signed write to the same doc, same posture,
  # must land — `Trust.with_local_node_trust/1` folds the node identity
  # into the trusted set. If this is green, the CX-oc30 fix is "sign the
  # audit write with the node context", not a policy change.
  test "MEASURE: a node-signed write to the audit doc lands under enforce", %{store: store} do
    strict!()
    enforce!()

    assert {:ok, ctx} = NodeIdentity.signing_context()

    result =
      CommitStoreClient.create_chained_commit(
        store,
        AuditLog.log_uuid(),
        text_update("audit"),
        %{},
        signing_context: ctx
      )

    assert %Commonplace.Store.Commit{} = result,
           "node-signed audit write was refused: #{inspect(result)}"
  end
end
