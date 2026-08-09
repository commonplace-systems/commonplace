defmodule Commonplace.Trust.CaptureRateTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.{AuditDispatcher, AuditLog, DenialCounter}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_capture_rate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    n = :rand.uniform(1_000_000_000)
    store = :"capture_store_#{n}"
    task_supervisor = :"capture_tasks_#{n}"
    dispatcher = :"capture_dispatcher_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"capture_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"capture_tss_#{n}",
       pending_imports_name: :"capture_pi_#{n}"}
    )

    start_supervised!({Task.Supervisor, name: task_supervisor}, id: task_supervisor)

    {public_key, private_key} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "capture-rate-fixture-#{n}",
      private_key: private_key,
      public_key: public_key
    }

    start_supervised!(
      {AuditDispatcher,
       name: dispatcher,
       store: store,
       task_supervisor: task_supervisor,
       signing_context_fn: fn -> {:ok, signing_context} end,
       boot_id: DenialCounter.boot_id(),
       flush_ms: 10,
       enabled: true},
      id: dispatcher
    )

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{
        signing_context.identity_uuid => Signing.encode_key(public_key)
      }
    })

    AuditLog.reset_rate_table()

    on_exit(fn ->
      AuditLog.detach()
      restore_env(:local_write_gate, old_gate)
      restore_env(:trust, old_trust)
      File.rm_rf!(dir)
    end)

    %{dispatcher: dispatcher, store: store}
  end

  test "detached audit handler exposes every denial as upstream loss and the counter advances",
       %{dispatcher: dispatcher, store: store} do
    AuditLog.detach()
    before = Commonplace.Trust.capture_rate(dispatcher: dispatcher)
    before_counter = DenialCounter.value()
    denials = 7

    drive_denials(store, denials)

    rate = Commonplace.Trust.capture_rate(dispatcher: dispatcher, since: before)
    report("handler_detached", rate)

    assert rate.boot_id == before.boot_id
    assert rate.emitted == denials
    assert rate.offered == 0
    assert rate.upstream_loss == denials
    assert DenialCounter.value() == before_counter + denials
    assert AuditDispatcher.accounted?(rate)
  end

  test "denials beyond the audit rate-limit cap remain visible as upstream loss",
       %{dispatcher: dispatcher, store: store} do
    AuditLog.attach(store, dispatcher: dispatcher)
    before = Commonplace.Trust.capture_rate(dispatcher: dispatcher)
    denials = 25

    drive_denials(store, denials)
    assert :ok = AuditDispatcher.flush(dispatcher, 5_000)

    rate = Commonplace.Trust.capture_rate(dispatcher: dispatcher, since: before)
    report("rate_limited", rate)

    assert rate.boot_id == before.boot_id
    assert rate.emitted == denials
    assert rate.offered == 20
    assert rate.recorded == 20
    assert rate.upstream_loss == denials - 20
    assert AuditDispatcher.accounted?(rate)
  end

  test "a normal below-cap run reports zero upstream loss", %{
    dispatcher: dispatcher,
    store: store
  } do
    AuditLog.attach(store, dispatcher: dispatcher)
    before = Commonplace.Trust.capture_rate(dispatcher: dispatcher)
    denials = 3

    drive_denials(store, denials)
    assert :ok = AuditDispatcher.flush(dispatcher, 5_000)

    rate = Commonplace.Trust.capture_rate(dispatcher: dispatcher, since: before)
    report("normal", rate)

    assert rate.boot_id == before.boot_id
    assert rate.emitted == denials
    assert rate.offered == denials
    assert rate.recorded == denials
    assert rate.upstream_loss == 0
    assert rate.capture_rate == 1.0
    assert AuditDispatcher.accounted?(rate)
  end

  test "a dispatcher that starts AFTER denials does not charge them to upstream loss", %{
    store: store
  } do
    # ⛔ THE REGRESSION THIS PINS: `emitted` lives in :persistent_term and
    # survives a dispatcher restart; the dispatcher's own buckets do not. If
    # capture_rate charged the difference to upstream_loss, every restart would
    # report all prior denials as fresh loss — AND THE IDENTITY WOULD STILL
    # BALANCE, making the false alarm indistinguishable from a real one.
    AuditLog.detach()
    drive_denials(store, 4)

    n = :rand.uniform(1_000_000_000)
    late = :"capture_late_dispatcher_#{n}"
    tasks = :"capture_late_tasks_#{n}"
    {public_key, private_key} = Signing.generate_keypair()

    ctx = %SigningContext{
      identity_uuid: "capture-late-#{n}",
      private_key: private_key,
      public_key: public_key
    }

    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    start_supervised!(
      {AuditDispatcher,
       name: late,
       store: store,
       task_supervisor: tasks,
       signing_context_fn: fn -> {:ok, ctx} end,
       boot_id: DenialCounter.boot_id(),
       flush_ms: 10,
       enabled: true},
      id: late
    )

    rate = Commonplace.Trust.capture_rate(dispatcher: late)
    report("late_dispatcher", rate)

    # The four earlier denials are attributed to the pre-dispatcher bucket,
    # NOT to upstream loss, and the identity still holds.
    assert rate.pre_dispatcher_emitted >= 4
    assert rate.upstream_loss == 0
    assert rate.emitted == rate.pre_dispatcher_emitted + rate.offered + rate.upstream_loss
    assert AuditDispatcher.accounted?(rate)

    # ...and the RATE is scored over this dispatcher's own window, not the
    # boot's. `recorded / emitted` would score a fresh dispatcher 0.0 for
    # denials that predate it — the same false alarm, one field over.
    assert rate.capture_rate == :not_applicable
  end

  test "a window with no denials reports :not_applicable, never 1.0", %{dispatcher: dispatcher} do
    # ⛔ 0/0 is neither 100% nor 0%. This is the lie CX-1n8y removed from the
    # mixed-plane scanner, and it is worse here: "capture_rate: 1.0" on an idle
    # window is exactly the reassuring green this ticket exists because someone
    # believed.
    before = Commonplace.Trust.capture_rate(dispatcher: dispatcher)
    idle = Commonplace.Trust.capture_rate(dispatcher: dispatcher, since: before)
    report("idle", idle)

    assert idle.emitted == 0
    assert idle.capture_rate == :not_applicable
  end

  test "a dispatcher that does not report emitted_at_start is REFUSED, not defaulted to 0", ctx do
    # ⛔ THE REGRESSION. Map.get(status, :emitted_at_start, 0) would treat a
    # dispatcher that does not REPORT the field as one that started with zero
    # prior denials — and the identity emitted == pre + offered + upstream_loss
    # STILL BALANCES, so the inflated upstream_loss is indistinguishable from a
    # real one. That is the very defect this function exists to remove,
    # reintroduced through a defaulting read.
    #
    # ⚠️ Reachable today: the RUNNING serve predates this instrument (CX-y4bq),
    # so its status/0 has no :emitted_at_start. A 0 there reads as "no upstream
    # loss" when the truth is "no instrument".
    defmodule OldDispatcher do
      # status/0 in the shape the pre-CX-m0qw build returns: no :emitted_at_start.
      def status(_server) do
        %{
          enabled: true,
          store: nil,
          boot_id: Commonplace.Trust.DenialCounter.boot_id(),
          offered: 0,
          recorded: 0,
          shed: 0,
          failed: 0,
          guarded: 0,
          queued: 0,
          in_flight: 0,
          max_queue: 256
        }
      end
    end

    _ = ctx

    report = Commonplace.Trust.capture_rate(dispatcher_mod: OldDispatcher, dispatcher: :ignored)

    assert report.error == :dispatcher_predates_instrument
    refute Map.has_key?(report, :upstream_loss)
    refute Map.has_key?(report, :capture_rate)
  end

  test "a NON-local_write audited event must not make upstream_loss negative", ctx do
    # ⛔ THE FIXTURE MONOCULTURE THIS FILE HAD. Every other test here drives
    # ONLY local_write denials, so `emitted` (incremented at the local_write
    # decision site) and `offered` (incremented for ALL NINE audited event
    # types) were IDENTICAL BY CONSTRUCTION — and a cross-population ratio
    # cannot fail a test whose fixtures produce one population.
    #
    # Observed live within a minute of deploy: emitted 3, offered 4,
    # upstream_loss -1, capture_rate 1.33. Both impossible.
    AuditLog.attach(ctx.store, dispatcher: ctx.dispatcher)
    before = Commonplace.Trust.capture_rate(dispatcher: ctx.dispatcher)

    # population 1: a real local_write denial -> increments BOTH counters
    drive_denials(ctx.store, 1)

    # population 2: any other audited event -> increments `offered` ONLY.
    # This is what real traffic does and what the fixtures never did.
    AuditDispatcher.offer(ctx.dispatcher, %{
      "event" => "commonplace.code.rejected.trust",
      "gate" => "code.trust",
      "boot_id" => Commonplace.Trust.DenialCounter.boot_id()
    })

    assert :ok = AuditDispatcher.flush(ctx.dispatcher, 5_000)
    rate = Commonplace.Trust.capture_rate(dispatcher: ctx.dispatcher, since: before)
    report("two_populations", rate)

    # The instrument must REFUSE rather than report an impossible number.
    assert rate[:error] == :cross_population_counters,
           "expected a refusal, got #{inspect(rate)}"

    refute Map.has_key?(rate, :upstream_loss),
           "a figure whose halves count different things must not be reported"

    refute Map.has_key?(rate, :capture_rate)
  end

  defp drive_denials(store, count) do
    for i <- 1..count do
      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.create_commit(store, UUID.uuid4(), text_update("denial #{i}"), nil)
    end
  end

  defp text_update(body) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "page.md")
    |> ContentType.insert_text(0, body)
    |> Yelixer.Encoding.encode_update()
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)

  defp report(label, rate) do
    IO.puts("CAPTURE_RATE #{label} #{inspect(rate)}")
  end
end
