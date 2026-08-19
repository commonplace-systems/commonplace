defmodule Commonplace.MUD.GhostReaperTest do
  @moduledoc """
  CX-3xwu (A) — 6 non-vacuous security pins for `Commonplace.MUD.GhostReaper`,
  the continuous autonomous ghost-reaper. Pins `run_once/1` directly (the
  testable core, pure of scheduling) against a real enforce-mode Store, a real
  `PresenceRegistry`, and a real `SessionLimit`.

  Each pin is built so that a broken/weakened implementation (heartbeat-keyed
  reaping, fail-open live-set, name/location-keyed classification, unbounded
  writes, or an AND-instead-of-OR union) would flip its assertions — not just
  "run and don't crash."
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{GhostReaper, PresenceRegistry, SessionLimit, Schemas}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  # A minimal live GenServer whose `:sys.get_state/1` shape is exactly what
  # `GhostReaper.safe_presence_filename/1` expects from a SessionLimit `:live`
  # pid — a REAL process with REAL state, not a fabricated `:sys.get_state`.
  defmodule FakeSession do
    use GenServer

    def start_link(fname), do: GenServer.start_link(__MODULE__, fname)

    @impl true
    def init(fname), do: {:ok, %{presence_filename: fname}}
  end

  # A "live" session with a state shape GhostReaper cannot map to a
  # presence_filename (`safe_presence_filename/1`'s catch-all `_ -> :error`).
  # This is a genuinely `:live`-attached SessionLimit pid whose state is just
  # unreadable — the deterministic way to exercise the fail-closed abort path
  # without racing a supervised singleton's restart.
  defmodule BadShapeSession do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, %{unexpected: :shape}}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ghostreaper_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"ghostreaper_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"ghostreaper_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"ghostreaper_tss_#{n}",
       pending_imports_name: :"ghostreaper_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v),
          do: Application.delete_env(:commonplace, key),
          else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    # `Commonplace.MUD.PresenceRegistry` and `Commonplace.MUD.SessionLimit` are
    # fixed-name singletons already started by the application supervision
    # tree (see `application.ex`) — reused directly here, exactly like
    # `cx_3xwu_who_filter_test.exs` does for the registry. We never restart
    # them; every process we register/attach into them is torn down at the
    # end of its own test so no state leaks across tests.

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    %{store: store, node_ctx: node_ctx, node_identity: node_identity, root: root}
  end

  # ---- helpers ----------------------------------------------------------

  defp reaper_state(root, store, node_ctx, node_identity, cap \\ 64) do
    %GhostReaper{
      store: store,
      root_uuid: root,
      node_ctx: node_ctx,
      node_identity: node_identity,
      interval_ms: 999_999,
      per_run_cap: cap
    }
  end

  defp create_room_dir!(parent, name, store, node_ctx) do
    {:ok, dir} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, dir)
    update = Encoding.encode_update(schema)

    r =
      CommitStoreClient.create_chained_commit(store, parent, update, %{kind: :regular},
        signing_context: node_ctx
      )

    refute match?({:error, _}, r), "dir entry must land"
    dir
  end

  # A node-signed presence-shape `.usr` with content the classifier reads as
  # `:presence` (BOTH `bound_identity` AND `status` present).
  defp create_presence_usr(dir_uuid, name, heartbeat_iso, store, node_ctx) do
    fname = "#{name}.usr"
    uuid = UUID.uuid4()

    doc = Yelixer.Doc.new(client_id: :erlang.phash2(uuid))
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", "usr")
    doc = ContentType.set_key(doc, "status", "starting")
    doc = ContentType.set_key(doc, "bound_identity", UUID.uuid4())
    doc = ContentType.set_key(doc, "heartbeat", heartbeat_iso)

    update = Encoding.encode_update(doc)

    r =
      CommitStoreClient.create_commit(store, uuid, update, nil, %{kind: :regular},
        signing_context: node_ctx
      )

    refute match?({:error, _}, r), "presence doc create must land"

    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema = Schema.add_file(schema, fname, uuid)
    dir_update = Encoding.encode_update(schema)

    r2 =
      CommitStoreClient.create_chained_commit(store, dir_uuid, dir_update, %{kind: :regular},
        signing_context: node_ctx
      )

    refute match?({:error, _}, r2), "presence .usr tree entry must land"
    fname
  end

  # An identity-shape `.usr` — `public_keys` + `first_seen`, NO `bound_identity`
  # — the classifier must never treat this as reapable presence.
  defp create_identity_usr(dir_uuid, name, store, node_ctx) do
    fname = "#{name}.usr"
    uuid = UUID.uuid4()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    doc = Yelixer.Doc.new(client_id: :erlang.phash2(uuid))
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", "usr")
    doc = ContentType.set_key(doc, "public_keys", ["k"])
    doc = ContentType.set_key(doc, "first_seen", now)
    doc = ContentType.set_key(doc, "last_seen", now)

    update = Encoding.encode_update(doc)

    r =
      CommitStoreClient.create_commit(store, uuid, update, nil, %{kind: :regular},
        signing_context: node_ctx
      )

    refute match?({:error, _}, r), "identity doc create must land"

    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema = Schema.add_file(schema, fname, uuid)
    dir_update = Encoding.encode_update(schema)

    r2 =
      CommitStoreClient.create_chained_commit(store, dir_uuid, dir_update, %{kind: :regular},
        signing_context: node_ctx
      )

    refute match?({:error, _}, r2), "identity .usr tree entry must land"
    fname
  end

  defp present?(dir_uuid, fname, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    match?({:ok, _}, Schema.get_entry(schema, fname))
  end

  defp stale_hb, do: DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()

  # -- liveness-injection helpers --

  defp register_live_in_registry(fname) do
    test_pid = self()

    pid =
      spawn(fn ->
        Registry.register(PresenceRegistry, fname, nil)
        send(test_pid, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 1000
    pid
  end

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
  end

  # Reserve+attach a fresh `FakeSession` pid into `SessionLimit`'s `:live` set
  # via the REAL admit/attach API, so `SessionLimit.live_pids/0` genuinely
  # includes it and `:sys.get_state/1` genuinely returns
  # `%{presence_filename: fname}`.
  defp attach_live_session(fname) do
    {:ok, pid} = FakeSession.start_link(fname)
    {:ok, ref} = SessionLimit.admit(make_ref())
    :ok = SessionLimit.attach(ref, pid)
    pid
  end

  # ---- PIN 1 — live-but-slow never reaped (load-out proof) --------------

  test "PIN 1: a live-but-slow session survives; an identically-stale unlive ghost is reaped", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    hb = stale_hb()
    create_presence_usr(root, "slow", hb, store, node_ctx)
    create_presence_usr(root, "deadghost", hb, store, node_ctx)

    slow_pid = attach_live_session("slow.usr")

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))

    # Both entries share the IDENTICAL stale heartbeat, so survival of "slow"
    # cannot be explained by recency — only by SessionLimit :live membership.
    refute "slow.usr" in reaped
    assert present?(root, "slow.usr", store)
    assert "deadghost.usr" in reaped
    refute present?(root, "deadghost.usr", store)

    GenServer.stop(slow_pid)
  end

  # ---- PIN 2 — fail-closed per run ---------------------------------------

  test "PIN 2: a healthy run reaps a dead ghost, but the SAME shape survives a degraded (aborted) run",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root
       } do
    hb = stale_hb()
    create_presence_usr(root, "willdie", hb, store, node_ctx)

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))
    assert "willdie.usr" in reaped
    refute present?(root, "willdie.usr", store)

    create_presence_usr(root, "willdie2", hb, store, node_ctx)

    # Degrade the live-set deterministically: attach a `:live` SessionLimit
    # pid whose state GhostReaper cannot map to a presence_filename — the
    # live-set can no longer be proven complete.
    {:ok, bad_pid} = BadShapeSession.start_link()
    {:ok, ref} = SessionLimit.admit(make_ref())
    :ok = SessionLimit.attach(ref, bad_pid)

    result = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))

    assert match?({:aborted, _}, result),
           "a degraded live-set must abort the WHOLE run, not reap around the gap"

    # "willdie" (from the healthy baseline run) proves this exact shape IS
    # reapable in principle — so "willdie2" surviving the degraded run is
    # explained by the abort, not by incidental non-classification.
    assert present?(root, "willdie2.usr", store)

    GenServer.stop(bad_pid)
  end

  # ---- PIN 3 — identity records excluded, contrasted with a real reap ----

  test "PIN 3: identity .usr records (root-level and under __identities__) are never reaped, while a real ghost is",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root
       } do
    identities_dir = create_room_dir!(root, "__identities__", store, node_ctx)

    create_identity_usr(root, "rootidentity", store, node_ctx)
    create_identity_usr(identities_dir, "jes", store, node_ctx)
    create_presence_usr(root, "realghost", stale_hb(), store, node_ctx)

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))

    refute "rootidentity.usr" in reaped
    assert present?(root, "rootidentity.usr", store)
    refute "jes.usr" in reaped
    assert present?(identities_dir, "jes.usr", store)

    # Contrast: the run WAS active (it reaped something), so the identity
    # exclusion is a real content-based discriminator, not a no-op run.
    assert "realghost.usr" in reaped
    refute present?(root, "realghost.usr", store)
  end

  # ---- PIN 4 — self-heal (reconnect survives the next cycle) ------------

  test "PIN 4: a reaped session that reconnects (live-backed again) is not re-reaped", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    create_presence_usr(root, "healme", stale_hb(), store, node_ctx)

    {:ok, reaped1} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))
    assert "healme.usr" in reaped1
    refute present?(root, "healme.usr", store)

    # Reconnect: a fresh live session attaches AND the presence doc is
    # re-created (simulating the reconnected client re-establishing presence).
    pid = attach_live_session("healme.usr")
    create_presence_usr(root, "healme", stale_hb(), store, node_ctx)

    {:ok, reaped2} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))

    refute "healme.usr" in reaped2
    assert present?(root, "healme.usr", store)

    GenServer.stop(pid)
  end

  # ---- PIN 5 — bounded cadence + no-write-on-empty ------------------------

  test "PIN 5a: per_run_cap bounds a single run's reap count", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    for i <- 1..5, do: create_presence_usr(root, "cap#{i}", stale_hb(), store, node_ctx)

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity, 3))

    # 5 dead ghosts, cap 3: the cap must bind exactly, not merely "some limit".
    assert length(reaped) == 3
  end

  test "PIN 5b: an empty run mutates nothing (no tree write, {:ok, []})", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    {:ok, before_commit} = CommitStoreClient.latest_commit(store, root)

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))
    assert reaped == []

    {:ok, after_commit} = CommitStoreClient.latest_commit(store, root)

    assert before_commit.id == after_commit.id,
           "an empty reap run must not touch the tree — the root dir's latest commit id is unchanged"

    # PIN 2 (the degraded/aborted run above) already proves no write happens
    # on abort — not duplicated here.
  end

  # ---- PIN 6 — dead-in-both / union-spares --------------------------------

  test "PIN 6: liveness in EITHER tracker alone spares a ghost; dead in BOTH is reaped", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    hb = stale_hb()
    create_presence_usr(root, "in-sl-only", hb, store, node_ctx)
    create_presence_usr(root, "in-reg-only", hb, store, node_ctx)
    create_presence_usr(root, "in-neither", hb, store, node_ctx)

    sl_pid = attach_live_session("in-sl-only.usr")
    reg_pid = register_live_in_registry("in-reg-only.usr")

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))

    refute "in-sl-only.usr" in reaped
    assert present?(root, "in-sl-only.usr", store)
    refute "in-reg-only.usr" in reaped
    assert present?(root, "in-reg-only.usr", store)

    assert "in-neither.usr" in reaped
    refute present?(root, "in-neither.usr", store)

    GenServer.stop(sl_pid)
    kill_and_wait(reg_pid)
  end
end
