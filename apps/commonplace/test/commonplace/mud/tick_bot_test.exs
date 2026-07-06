defmodule Commonplace.MUD.TickBotTest do
  use ExUnit.Case

  alias Commonplace.MUD.{Bootstrap, Schemas, TickBot, Topics}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_tick_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    # CX-pvrl: this module doesn't exercise World.move, only TickBot
    # leadership — so it gets its OWN uniquely-named Bursar rather than
    # registering under the default `Commonplace.Green.Bursar` name.
    # The application boots an unconditional `Commonplace.MUD.TickBot`
    # singleton (default name, real 1s heartbeat, `bursar:` defaulting
    # to the literal `Bursar` atom) for the whole `mix test` run; if this
    # module's Bursar were registered under that default name, the
    # ambient singleton would find it and race this module's own
    # TickBot instances for the same "__singletons/tick_bot" lease
    # (intermittent :not_leader flake). A uniquely-named Bursar is
    # invisible to that ambient TickBot.
    bursar_name = :"tick_bot_test_bursar_#{:rand.uniform(1_000_000)}"

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        name: bursar_name,
        sweep_interval: 60_000
      )

    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)

    %{store: store, root: root_uuid, bursar: bursar_pid}
  end

  defp start_tickbot(ctx, extra_opts \\ []) do
    name = :"tick_bot_#{:rand.uniform(1_000_000)}"

    # extra_opts FIRST: Keyword.get takes the first match, so tests can
    # override the defaults below. orphan_sweep defaults OFF here (prod
    # default is on) — the contention tests in this file exercise plain
    # deny/backoff semantics; sweep behavior gets its own tests.
    {:ok, pid} =
      TickBot.start_link(
        extra_opts ++
          [
            name: name,
            store: ctx.store,
            root_uuid: ctx.root,
            heartbeat_ms: 999_999,
            auto_start: false,
            bursar: ctx.bursar,
            orphan_sweep: false
          ]
      )

    {pid, name}
  end

  defp add_dir_entry(parent, name, child, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, child)
    update = Encoding.encode_update(schema)
    CommitStore.create_chained_commit(store, parent, update)
  end

  test "fountain in seeded clearing emits a burble on tick", ctx do
    {:ok, _} = Bootstrap.seed(ctx.root, ctx.store)
    {_pid, name} = start_tickbot(ctx)

    # Find the clearing's UUID so we can subscribe to its red channel
    {:ok, root_schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    {:ok, clearing} = Schema.get_entry(root_schema, "clearing")

    Topics.subscribe_room(clearing.node_id)

    # First tick fires immediately because last_tick is 0 → elapsed >= interval
    :ok = TickBot.tick_now(name)

    assert_receive {"red:" <> _, %{kind: :custom, text: "The fountain burbles softly."}}, 100
  end

  test "tick fires only once per interval window", ctx do
    {:ok, _} = Bootstrap.seed(ctx.root, ctx.store)
    {_pid, name} = start_tickbot(ctx)

    {:ok, root_schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    {:ok, clearing} = Schema.get_entry(root_schema, "clearing")
    Topics.subscribe_room(clearing.node_id)

    :ok = TickBot.tick_now(name)
    assert_receive {"red:" <> _, %{kind: :custom}}, 100

    # Immediate second tick: not enough wall-clock has passed → no fire
    :ok = TickBot.tick_now(name)
    refute_receive {"red:" <> _, %{kind: :custom}}, 50
  end

  test "objects without tick_interval_ms are ignored", ctx do
    # Build a tiny world: one room with an inert object
    {:ok, obj_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "rock", description: "A rock."}),
        ctx.store
      )

    {:ok, room_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Cave", description: "Damp."}),
        ctx.store
      )

    add_dir_entry(room_uuid, "rock.obj", obj_uuid, ctx.store)
    add_dir_entry(ctx.root, "cave", room_uuid, ctx.store)

    {_pid, name} = start_tickbot(ctx)
    Topics.subscribe_room(room_uuid)

    :ok = TickBot.tick_now(name)
    refute_receive {"red:" <> _, _}, 50
  end

  test "room-level tick_interval_ms fires the room's own tick_message", ctx do
    {:ok, room_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{
          name: "Wind Tunnel",
          description: "Air rushes past.",
          tick_interval_ms: 100,
          tick_message: "The wind howls."
        }),
        ctx.store
      )

    add_dir_entry(ctx.root, "tunnel", room_uuid, ctx.store)

    {_pid, name} = start_tickbot(ctx)
    Topics.subscribe_room(room_uuid)

    :ok = TickBot.tick_now(name)
    assert_receive {"red:" <> _, %{kind: :custom, text: "The wind howls."}}, 100
  end

  # Move #4 (CX-tdkq.7): TickBot's :global registration is retired.
  # Leadership is a green-token lease ("__singletons/tick_bot"): every
  # TickBot tries to acquire each tick; only the holder ticks. Holder
  # crash → TTL expiry → another instance acquires (failover bounded by
  # the lease TTL). No Bursar reachable → idle (fail-closed) — the
  # bare-mix-run temp node case.
  describe "lease-based leadership" do
    defp seeded_tunnel(ctx) do
      {:ok, room_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{
            name: "Wind Tunnel",
            description: "Air rushes past.",
            tick_interval_ms: 100,
            tick_message: "The wind howls."
          }),
          ctx.store
        )

      add_dir_entry(ctx.root, "tunnel", room_uuid, ctx.store)
      Topics.subscribe_room(room_uuid)
      room_uuid
    end

    test "tick_now returns :not_leader and stays silent when the lease is held elsewhere", ctx do
      seeded_tunnel(ctx)

      {:ok, _} =
        Commonplace.Green.Bursar.acquire(
          ctx.bursar, "__singletons/tick_bot", "some-other-node")

      {_pid, name} = start_tickbot(ctx, holder: "me")

      assert :not_leader = TickBot.tick_now(name)
      refute_receive {"red:" <> _, _}, 50
    end

    test "leader acquires the lease and ticks", ctx do
      seeded_tunnel(ctx)
      {_pid, name} = start_tickbot(ctx, holder: "me")

      assert :ok = TickBot.tick_now(name)
      assert_receive {"red:" <> _, %{kind: :custom, text: "The wind howls."}}, 100

      assert {:held, %{holder: "me"}} =
               Commonplace.Green.Bursar.query(ctx.bursar, "__singletons/tick_bot")
    end

    test "renewal keeps the leader alive past the original TTL", ctx do
      seeded_tunnel(ctx)
      {_pid, name} = start_tickbot(ctx, holder: "me", lease_ttl_ms: 300)

      assert :ok = TickBot.tick_now(name)

      # Tick repeatedly across > 2×TTL; each due tick renews (memory-only).
      # The manual sweeps would expire a non-renewing leader.
      for _ <- 1..14 do
        Process.sleep(50)
        send(ctx.bursar, :sweep_ttl)
        TickBot.tick_now(name)
      end

      assert :ok = TickBot.tick_now(name)

      assert {:held, %{holder: "me"}} =
               Commonplace.Green.Bursar.query(ctx.bursar, "__singletons/tick_bot")
    end

    test "failover: a second TickBot takes over after the dead leader's TTL expires", ctx do
      seeded_tunnel(ctx)
      ttl = 200

      {pid_a, name_a} = start_tickbot(ctx, holder: "a", lease_ttl_ms: ttl)
      assert :ok = TickBot.tick_now(name_a)

      # Leader dies without releasing.
      GenServer.stop(pid_a)

      {_pid_b, name_b} = start_tickbot(ctx, holder: "b", lease_ttl_ms: ttl)
      # Lease still alive — b must NOT lead yet.
      assert :not_leader = TickBot.tick_now(name_b)

      started = System.monotonic_time(:millisecond)

      result =
        Enum.reduce_while(1..100, :timeout, fn _, _ ->
          send(ctx.bursar, :sweep_ttl)

          case TickBot.tick_now(name_b) do
            :ok -> {:halt, :leader}
            :not_leader -> Process.sleep(25) && {:cont, :timeout}
          end
        end)

      elapsed = System.monotonic_time(:millisecond) - started
      assert result == :leader
      assert elapsed <= 2 * ttl + 200, "failover took #{elapsed}ms"

      assert {:held, %{holder: "b"}} =
               Commonplace.Green.Bursar.query(ctx.bursar, "__singletons/tick_bot")
    end

    test "no bursar reachable → :not_leader, no crash (fail-closed)", ctx do
      seeded_tunnel(ctx)
      GenServer.stop(ctx.bursar)

      {_pid, name} = start_tickbot(ctx, holder: "me")

      assert :not_leader = TickBot.tick_now(name)
      refute_receive {"red:" <> _, _}, 50
    end

    # CX-sqyc: a denied contender must sleep out the lease TTL instead
    # of re-acquiring every heartbeat — 1Hz denial retries persisted a
    # red event each and crashed the dogfood serve's Bursar.
    test "denied contender backs off to the lease TTL before re-contending", ctx do
      seeded_tunnel(ctx)

      {:ok, _} =
        Commonplace.Green.Bursar.acquire(ctx.bursar, "__singletons/tick_bot", "other")

      {_pid, name} = start_tickbot(ctx, holder: "me", lease_ttl_ms: 300)

      assert :not_leader = TickBot.tick_now(name)

      :ok = Commonplace.Green.Bursar.release(ctx.bursar, "__singletons/tick_bot", "other")

      # Lease is free, but the contender is inside its backoff window —
      # it must not even attempt an acquire yet.
      assert :not_leader = TickBot.tick_now(name)
      assert :available = Commonplace.Green.Bursar.query(ctx.bursar, "__singletons/tick_bot")

      Process.sleep(350)
      assert :ok = TickBot.tick_now(name)
    end

    # CX-sqyc boot orphan sweep: a serve restarting after a crash may
    # find the lease held by a dead incarnation, re-clocked to a full
    # TTL by Bursar.load_state. On the singleton host, a denial before
    # this instance has ever led breaks the stale lease and takes over.
    test "orphan sweep: pre-leadership denial breaks a stale lease and takes over", ctx do
      seeded_tunnel(ctx)

      {:ok, _} =
        Commonplace.Green.Bursar.acquire(
          ctx.bursar, "__singletons/tick_bot", "dead-incarnation")

      {_pid, name} = start_tickbot(ctx, holder: "me", orphan_sweep: true)

      assert :ok = TickBot.tick_now(name)

      assert {:held, %{holder: "me"}} =
               Commonplace.Green.Bursar.query(ctx.bursar, "__singletons/tick_bot")
    end

    test "orphan sweep does not steal a lease that moved after this instance led", ctx do
      seeded_tunnel(ctx)
      {_pid, name} = start_tickbot(ctx, holder: "me", orphan_sweep: true, lease_ttl_ms: 60_000)

      assert :ok = TickBot.tick_now(name)

      # The lease legitimately moves (break-glass + new holder). The
      # once-leader instance must back off, not sweep.
      :ok = Commonplace.Green.Bursar.force_release(ctx.bursar, "__singletons/tick_bot")

      {:ok, _} =
        Commonplace.Green.Bursar.acquire(ctx.bursar, "__singletons/tick_bot", "usurper")

      assert :not_leader = TickBot.tick_now(name)

      assert {:held, %{holder: "usurper"}} =
               Commonplace.Green.Bursar.query(ctx.bursar, "__singletons/tick_bot")
    end

    # CX-tdkq.32: TickBot is an internal system caller — its default
    # holder must be a NAMED principal (derived from the node identity),
    # never a free string. Only exercised when the test does NOT
    # override `holder:` (every other test in this file does, to keep
    # multiple TickBots from contending on the same lease).
    test "default holder is prefixed with the node identity, not a bare node() string", ctx do
      {:ok, node_identity} = Commonplace.Crypto.NodeIdentity.identity()
      {_pid, name} = start_tickbot(ctx)

      assert :ok = TickBot.tick_now(name)

      assert {:held, %{holder: holder}} =
               Commonplace.Green.Bursar.query(ctx.bursar, "__singletons/tick_bot")

      assert String.starts_with?(holder, "#{node_identity}/tick_bot@")
    end
  end
end
