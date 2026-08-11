defmodule Commonplace.Presence.ReaperTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Presence
  alias Commonplace.Presence.Reaper
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability

  setup do
    {:ok, _} = Application.ensure_all_started(:commonplace)

    suffix = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "cp_reaper_test_#{suffix}")
    File.mkdir_p!(dir)
    store = :"commit_store_reaper_#{suffix}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"reaper_store_sup_#{suffix}",
       commit_store_name: store,
       trust_side_store_name: :"reaper_tss_#{suffix}",
       pending_imports_name: :"reaper_pi_#{suffix}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      gate: Application.get_env(:commonplace, :local_write_gate),
      trust: Application.get_env(:commonplace, :trust)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :local_write_gate, :off)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    on_exit(fn ->
      put_or_delete(:data_dir, old.data_dir)
      put_or_delete(:local_write_gate, old.gate)
      put_or_delete(:trust, old.trust)
      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    root = UUID.uuid4()

    assert %Commit{} =
             CommitStore.create_commit(
               store,
               root,
               Yelixer.Encoding.encode_update(Schema.new_schema()),
               nil
             )

    %{root: root, store: store, node_ctx: node_ctx}
  end

  test "measured bridge loop lands a scoped reap and reports the write effect", ctx do
    bridge = create_bridge!(ctx, lease_ttl_ms: 1)
    now = after_heartbeat(bridge.uuid, ctx.store, 2)
    Application.put_env(:commonplace, :local_write_gate, :enforce)
    parent = self()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log([level: :info], fn ->
        outcomes = Reaper.reap(ctx.root, ctx.store, now: now)
        send(parent, {:outcomes, outcomes})
        Reaper.report_outcomes(outcomes)
      end)

    assert_receive {:outcomes, [%{outcome: :landed, name: "__git-bridge.bot"}]}
    assert log =~ "Presence reaper landed 1 expired entries: __git-bridge.bot"
    refute log =~ "DENIED"
    assert :error = Schema.get_entry(load_schema(ctx.root, ctx.store), "__git-bridge.bot")

    assert {:ok, root_commit} = CommitStore.latest_commit(ctx.store, ctx.root)

    assert %{
             entry_name: "__git-bridge.bot",
             presence_uuid: presence_uuid,
             root_uuid: root_uuid,
             last_heartbeat: last_heartbeat,
             ttl_ms: 1,
             now: evidence_now
           } = root_commit.metadata.presence_janitor

    assert presence_uuid == bridge.uuid
    assert root_uuid == ctx.root
    assert last_heartbeat == Presence.read(bridge.uuid, ctx.store)["heartbeat"]
    assert evidence_now == DateTime.to_iso8601(now)
  end

  test "denied reap is an ERROR and never increments the landed count", ctx do
    bridge = create_bridge!(ctx, name: "denied-bridge", lease_ttl_ms: 1)
    now = after_heartbeat(bridge.uuid, ctx.store, 2)
    {_pub, wrong_priv} = Signing.generate_keypair()
    {wrong_pub, _other_priv} = Signing.generate_keypair()

    wrong_ctx = %SigningContext{
      identity_uuid: "not-the-node",
      public_key: wrong_pub,
      private_key: wrong_priv
    }

    Application.put_env(:commonplace, :local_write_gate, :enforce)
    parent = self()

    log =
      capture_log(fn ->
        outcomes = Reaper.reap(ctx.root, ctx.store, now: now, signing_context: wrong_ctx)
        send(parent, {:outcomes, outcomes})
        Reaper.report_outcomes(outcomes)
      end)

    assert_receive {:outcomes, [%{outcome: :denied, name: "denied-bridge.bot"}]}
    assert log =~ "[error] Presence reaper DENIED denied-bridge.bot"
    refute log =~ "Presence reaper landed"
    assert {:ok, _} = Schema.get_entry(load_schema(ctx.root, ctx.store), "denied-bridge.bot")
  end

  test "janitor scope property refuses a removal against a non-expired entry", ctx do
    bridge = create_bridge!(ctx, name: "fresh-bridge", lease_ttl_ms: 5_000)
    content = Presence.read(bridge.uuid, ctx.store)
    {:ok, heartbeat, _offset} = DateTime.from_iso8601(content["heartbeat"])
    now = DateTime.add(heartbeat, 1_000, :millisecond)

    evidence = %{
      entry_name: "fresh-bridge.bot",
      presence_uuid: bridge.uuid,
      root_uuid: ctx.root,
      last_heartbeat: content["heartbeat"],
      ttl_ms: 5_000,
      now: DateTime.to_iso8601(now)
    }

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    assert {:error, {:trust_rejected, :presence_janitor_scope_invalid}} =
             Presence.remove("fresh-bridge.bot", ctx.root, ctx.store,
               signing_context: ctx.node_ctx,
               janitor_evidence: evidence
             )

    assert {:ok, _} = Schema.get_entry(load_schema(ctx.root, ctx.store), "fresh-bridge.bot")
  end

  test "permissive control keeps a heartbeating bridge and reaps an expired peer", ctx do
    fresh = create_bridge!(ctx, name: "heartbeating", lease_ttl_ms: 5_000)
    expired = create_bridge!(ctx, name: "expired", lease_ttl_ms: 1)
    now = after_heartbeat(expired.uuid, ctx.store, 1_000)
    Application.put_env(:commonplace, :local_write_gate, :off)

    assert [%{outcome: :landed, name: "expired.bot"}] =
             Reaper.reap(ctx.root, ctx.store, now: now)

    root = load_schema(ctx.root, ctx.store)
    assert {:ok, %{node_id: fresh_uuid}} = Schema.get_entry(root, "heartbeating.bot")
    assert fresh_uuid == fresh.uuid
    assert :error = Schema.get_entry(root, "expired.bot")
  end

  test "reaper honors interactive, service, and legacy temporal class TTLs", ctx do
    interactive =
      create_bridge!(ctx,
        name: "interactive",
        type: :usr,
        lease_ttl_ms: Presence.default_lease_ttl_ms(:usr)
      )

    service =
      create_bridge!(ctx,
        name: "service",
        type: :bot,
        lease_ttl_ms: Presence.default_lease_ttl_ms(:bot)
      )

    legacy =
      create_bridge!(ctx,
        name: "legacy-service",
        type: :bot,
        lease_ttl_ms: Presence.default_lease_ttl_ms(:bot)
      )

    legacy_doc =
      legacy.uuid
      |> load_doc(ctx.store)
      |> ContentType.delete_key("lease_version")
      |> ContentType.delete_key("lease_ttl_ms")

    assert %Commit{} =
             CommitStore.create_chained_commit(
               ctx.store,
               legacy.uuid,
               Yelixer.Encoding.encode_update(legacy_doc)
             )

    latest_heartbeat =
      [interactive.uuid, service.uuid, legacy.uuid]
      |> Enum.map(fn uuid ->
        {:ok, heartbeat, _offset} =
          uuid |> Presence.read(ctx.store) |> Map.fetch!("heartbeat") |> DateTime.from_iso8601()

        heartbeat
      end)
      |> Enum.max_by(&DateTime.to_unix(&1, :microsecond))

    now = DateTime.add(latest_heartbeat, 31_000, :millisecond)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    assert [%{outcome: :landed, name: "interactive.usr"}] =
             Reaper.reap(ctx.root, ctx.store, now: now)

    root = load_schema(ctx.root, ctx.store)
    assert :error = Schema.get_entry(root, "interactive.usr")
    assert {:ok, %{node_id: service_uuid}} = Schema.get_entry(root, "service.bot")
    assert {:ok, %{node_id: legacy_uuid}} = Schema.get_entry(root, "legacy-service.bot")
    assert service_uuid == service.uuid
    assert legacy_uuid == legacy.uuid
  end

  test "migration names a torn lease instead of treating it as legacy", ctx do
    bridge = create_bridge!(ctx, name: "torn", lease_ttl_ms: 1)
    doc = load_doc(bridge.uuid, ctx.store)
    doc = ContentType.delete_key(doc, "lease_ttl_ms")

    assert %Commit{} =
             CommitStore.create_chained_commit(
               ctx.store,
               bridge.uuid,
               Yelixer.Encoding.encode_update(doc)
             )

    assert [
             %{
               outcome: :skipped,
               name: "torn.bot",
               reason: :presence_lease_torn_missing_ttl
             }
           ] = Reaper.reap(ctx.root, ctx.store)
  end

  test "find_stale is empty when the root has no presence entries", ctx do
    assert Reaper.find_stale(ctx.root, ctx.store) == []
  end

  @tag :skip
  test "LEASE FAMILY SEAM: progress-witness lease expiry supplies signed witness terms to the scoped janitor" do
    flunk("placeholder for the coming Green progress-witness lease member")
  end

  defp create_bridge!(ctx, opts) do
    name = Keyword.get(opts, :name, "__git-bridge")
    type = Keyword.get(opts, :type, :bot)
    ttl = Keyword.fetch!(opts, :lease_ttl_ms)
    {pub, priv} = Signing.generate_keypair()
    identity = "fixture-#{name}-#{System.unique_integer([:positive])}"
    signing_context = %SigningContext{identity_uuid: identity, public_key: pub, private_key: priv}

    {:ok, cap} =
      Capability.issue(
        ctx.node_ctx,
        {identity, pub},
        %{verbs: [:write], scope: {:presence, identity}, caveats: %{}},
        nil,
        store: ctx.store
      )

    :ok = CommitStore.store_capability(ctx.store, cap)
    creds = [signing_context: signing_context, cert_cids: [cap.id], lease_ttl_ms: ttl]
    {:ok, uuid} = Presence.create(name, type, ctx.root, ctx.store, creds)
    %{uuid: uuid, creds: creds}
  end

  defp after_heartbeat(uuid, store, milliseconds) do
    {:ok, heartbeat, _offset} =
      uuid |> Presence.read(store) |> Map.fetch!("heartbeat") |> DateTime.from_iso8601()

    DateTime.add(heartbeat, milliseconds, :millisecond)
  end

  defp load_schema(uuid, store) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc
  end

  defp load_doc(uuid, store) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:commonplace, key)
  defp put_or_delete(key, value), do: Application.put_env(:commonplace, key, value)
end
