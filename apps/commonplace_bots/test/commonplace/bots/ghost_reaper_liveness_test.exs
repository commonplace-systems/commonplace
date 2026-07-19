defmodule Commonplace.Bots.GhostReaperLivenessTest do
  @moduledoc """
  cp-plan #8915 (P1) — "registration IS liveness." A `Commonplace.Bots
  .Dispatcher`-registered autonomous bot's `.usr` presence must never be
  reaped by `Commonplace.MUD.GhostReaper`, no matter how long since its
  last tick (Camillo's live incident: a 3600s autonomous cadence against
  the reaper's 300s default left his `.usr` looking exactly like an
  abandoned ghost for most of every hour). Unregistering — or the
  dispatcher PROCESS itself dying, with no explicit unregister call at
  all — must make the same `.usr` reapable again: registration is a
  RUNTIME fact, not a persisted one; nothing here should survive the
  process that claimed it.

  Pins authored FROM THE SPEC (lesson #8): (1) a registered autonomous
  bot's `.usr` survives a reaper run with a stale heartbeat; (2) an
  UNREGISTERED bot with the identical stale heartbeat is reaped as
  before — no blanket widening of what the reaper spares; (3) the
  LIVENESS-IS-RUNTIME pin, in two halves — explicit unregister makes the
  `.usr` reapable again, and SEPARATELY, simulated dispatcher death
  (killing the registering process, no unregister call) does too.

  Mirrors `ghost_reaper_test.exs`'s fixtures (raw content-shaped presence
  docs, `reaper_state/4`, `stale_hb/0`, `present?/3`) and
  `heartbeat_test.exs`'s pattern of swapping in a Dispatcher bound to
  THIS test's own isolated store.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Dispatcher
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{GhostReaper, Schemas}
  alias Commonplace.Store.{CommitStoreClient, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_ghostlive_#{n}")
    File.mkdir_p!(dir)
    store = :"ghostlive_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"ghostlive_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"ghostlive_tss_#{n}",
       pending_imports_name: :"ghostlive_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_ghostlive_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"ghostlive_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    # Swap in a Dispatcher bound to THIS test's store (mirrors heartbeat_test.exs).
    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Dispatcher)

    {:ok, dispatcher_pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Dispatcher,
           [
             worker_hook: fn _room, _entity, _event -> :ok end,
             rate_limit_enabled: false,
             store: store,
             node_ctx: node_ctx
           ]},
          id: Dispatcher
        )
      )

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Dispatcher)
      Process.sleep(50)

      {:ok, _pid} =
        Supervisor.start_child(bots_sup, Supervisor.child_spec({Dispatcher, []}, id: Dispatcher))

      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    %{
      store: store,
      secrets: secrets,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      dispatcher_pid: dispatcher_pid
    }
  end

  # ---- helpers (mirrors ghost_reaper_test.exs) ----

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

  # A node-signed presence-shape `.usr` (content the classifier reads as
  # `:presence`) with an explicit, deliberately STALE heartbeat — proving
  # (with `ghost_reaper_test.exs`'s own PIN 1) that reap-eligibility is
  # keyed on liveness membership, never on heartbeat recency.
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

  defp present?(dir_uuid, fname, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    match?({:ok, _}, Schema.get_entry(schema, fname))
  end

  defp stale_hb, do: DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()

  # A cadence long enough that no tick will fire during the test — the
  # registration side effect (PresenceRegistry membership) is what's under
  # test, not the tick machinery.
  @no_tick_cadence 999_999_999

  ## ---- PIN 1: a registered bot with zero heartbeats is spared ----

  test "PIN 1: a registered autonomous bot's .usr survives a reaper run with a stale heartbeat",
       %{
         store: store,
         secrets: secrets,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root
       } do
    create_presence_usr(root, "camillo", stale_hb(), store, node_ctx)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", root, root, @no_tick_cadence,
        secret_store: secrets
      )

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))

    refute "camillo.usr" in reaped
    assert present?(root, "camillo.usr", store)
  end

  ## ---- PIN 2: an UNREGISTERED bot with the same shape is reaped (no blanket widening) ----

  test "PIN 2: an UNREGISTERED bot with the identical stale heartbeat is reaped as before", %{
    store: store,
    secrets: secrets,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    hb = stale_hb()
    create_presence_usr(root, "camillo", hb, store, node_ctx)
    create_presence_usr(root, "stranger", hb, store, node_ctx)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", root, root, @no_tick_cadence,
        secret_store: secrets
      )

    {:ok, reaped} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))

    # The registered bot is spared...
    refute "camillo.usr" in reaped
    assert present?(root, "camillo.usr", store)

    # ...but the identically-stale, NEVER-registered stranger is reaped —
    # proof this isn't a blanket widening of what the reaper spares.
    assert "stranger.usr" in reaped
    refute present?(root, "stranger.usr", store)
  end

  ## ---- PIN 3: LIVENESS-IS-RUNTIME (the one that matters) ----

  test "PIN 3a: unregistering makes the .usr reapable again", %{
    store: store,
    secrets: secrets,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    create_presence_usr(root, "camillo", stale_hb(), store, node_ctx)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", root, root, @no_tick_cadence,
        secret_store: secrets
      )

    {:ok, reaped1} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))
    refute "camillo.usr" in reaped1
    assert present?(root, "camillo.usr", store)

    :ok = Dispatcher.unregister_autonomous_bot("camillo.bot")

    {:ok, reaped2} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))
    assert "camillo.usr" in reaped2
    refute present?(root, "camillo.usr", store)
  end

  test "PIN 3b: simulated dispatcher DEATH (no explicit unregister) makes the .usr reapable again",
       %{
         store: store,
         secrets: secrets,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root,
         dispatcher_pid: dispatcher_pid
       } do
    create_presence_usr(root, "camillo", stale_hb(), store, node_ctx)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", root, root, @no_tick_cadence,
        secret_store: secrets
      )

    {:ok, reaped1} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))
    refute "camillo.usr" in reaped1
    assert present?(root, "camillo.usr", store)

    # Kill the REGISTERING process directly — no unregister call anywhere.
    # Registry's own process-monitor-based cleanup (NOT a `terminate/2`
    # callback, which a brutal kill skips) is what must drop the
    # membership — this is the mechanism the fix actually relies on.
    ref = Process.monitor(dispatcher_pid)
    Process.exit(dispatcher_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dispatcher_pid, _}, 1000

    {:ok, reaped2} = GhostReaper.run_once(reaper_state(root, store, node_ctx, node_identity))
    assert "camillo.usr" in reaped2
    refute present?(root, "camillo.usr", store)
  end
end
