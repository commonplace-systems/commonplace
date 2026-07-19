defmodule Commonplace.Bots.HeartbeatTest do
  @moduledoc """
  Camillo C3b/C3d — the AUTONOMOUS heartbeat source.

  Heartbeat ticks are a FIRST-CLASS, room-independent dispatcher entrypoint
  (`register_autonomous_bot/5`): a bot's mind ticks whether or not any chat
  surface has subscribed its rooms. The agenda skip-check reads the bot's
  `home/agenda` note-meta by a uuid CACHED at register time (cheap per tick),
  self-healing on a miss. These tests provision a real citizen (so `home/agenda`
  + presence exist) and drive ticks deterministically.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Agenda, Citizen, Dispatcher, MudContext, Transcript}
  alias Commonplace.Bots.Worker.{Loop, Tools}
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Presence
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_heartbeat_#{n}")
    File.mkdir_p!(dir)
    store = :"heartbeat_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"heartbeat_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"heartbeat_tss_#{n}",
       pending_imports_name: :"heartbeat_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_heartbeat_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"heartbeat_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # Swap in a Dispatcher bound to THIS test's store (so its autonomous
    # resolution + reads hit the same tree the citizen was provisioned into).
    test_pid = self()
    hook = fn room, entity, event -> send(test_pid, {:wake, room, entity.name, event}) end

    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Commonplace.Bots.Dispatcher,
           [worker_hook: hook, rate_limit_enabled: false, store: store, node_ctx: node_ctx]},
          id: Commonplace.Bots.Dispatcher
        )
      )

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)
      # Let any in-flight best-effort tasks drain before the store is gone.
      Process.sleep(100)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, []},
            id: Commonplace.Bots.Dispatcher
          )
        )

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

    # The MUD root (node-signed).
    mud_root = UUID.uuid4()

    CommitStore.create_commit(
      store,
      mud_root,
      Encoding.encode_update(Schema.new_schema()),
      nil,
      %{},
      signing_context: node_ctx
    )

    %{store: store, mud_root: mud_root, secrets: secrets, node_ctx: node_ctx}
  end

  ## Fixtures

  defp mint_text_doc(store, name, body) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)
    uuid
  end

  # A minimal .bot CHARTER dir (persona.md + trigger.regex) — the entity dir the
  # dispatcher loads. The desk (memory/agenda) lives under the home, not here.
  defp mint_bot_dir(store) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc(store, "persona.md", "I am camillo."))
      |> Schema.add_file("trigger.regex", mint_text_doc(store, "trigger.regex", "(?i)@camillo"))

    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, Encoding.encode_update(schema), nil)
    uuid
  end

  # Provision "camillo" as a citizen (home + presence + home/agenda) and resolve
  # his MUD ctx (for appending to the home agenda in tests).
  defp provision_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, mud_ctx}
  end

  defp tick(name),
    do: send(Process.whereis(Commonplace.Bots.Dispatcher), {:autonomous_tick, name})

  ## First-class chatless registration

  test "a bot registered for autonomous ticks fires — with NO room subscribed", ctx do
    {_prov, mud_ctx} = provision_camillo(ctx)
    :ok = Agenda.append(%{"text" => "do a thing"}, mud_ctx)
    bot_dir = mint_bot_dir(ctx.store)

    # NO subscribe_room — the mind ticks purely on its own registration.
    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 50,
        secret_store: ctx.secrets
      )

    assert_receive {:wake, "camillo", "camillo", event}, 2_000
    assert event["kind"] == "heartbeat"
    assert event["verb"] == "heartbeat"
    assert event["agenda_empty"] == false
    assert Dispatcher.registered_rooms() == %{}
  end

  test "register caches the home-agenda uuid at register time", ctx do
    {prov, _mud_ctx} = provision_camillo(ctx)
    bot_dir = mint_bot_dir(ctx.store)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets
      )

    auto = Dispatcher.registered_autonomous_bots()
    assert auto["camillo"].home_agenda_uuid == prov.agenda_uuid
  end

  ## Wake vs skip (autonomous: thread is trivially quiet, so wake iff agenda non-empty)

  test "wake when the home-agenda is non-empty", ctx do
    {_prov, mud_ctx} = provision_camillo(ctx)
    :ok = Agenda.append(%{"text" => "unfiled pin"}, mud_ctx)
    bot_dir = mint_bot_dir(ctx.store)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets
      )

    tick("camillo")

    assert_receive {:wake, "camillo", "camillo", event}, 2_000
    assert event["agenda_empty"] == false
  end

  test "skip when the home-agenda is empty — but presence STILL beats", ctx do
    {prov, _mud_ctx} = provision_camillo(ctx)
    bot_dir = mint_bot_dir(ctx.store)

    ts0 = Presence.read(prov.presence_uuid, ctx.store)["heartbeat"]
    assert is_binary(ts0)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets
      )

    tick("camillo")

    # Empty agenda + trivially-quiet thread → no worker wake...
    refute_receive {:wake, _, _, _}, 400

    # ...but the presence keep-alive beat still advances (resting bot stays alive).
    Commonplace.Tree.DocCache.clear()
    ts1 = Presence.read(prov.presence_uuid, ctx.store)["heartbeat"]
    assert is_binary(ts1)
    assert ts1 != ts0, "a :skip tick must still refresh the bot's presence heartbeat"
  end

  # C5c-i PIN (d): a heartbeat :skip decision never reaches Worker.run at
  # all (the dispatcher short-circuits before spawning a worker for an
  # empty-agenda, trivially-quiet tick) — so no turn ever happened, and the
  # transcript must be byte-unchanged across the tick.
  test "PIN (d): a heartbeat :skip tick produces NO transcript entry", ctx do
    {_prov, mud_ctx} = provision_camillo(ctx)
    bot_dir = mint_bot_dir(ctx.store)

    assert Transcript.read(mud_ctx) == []

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets
      )

    tick("camillo")

    refute_receive {:wake, _, _, _}, 400

    Commonplace.Tree.DocCache.clear()
    assert Transcript.read(mud_ctx) == []
  end

  ## Self-heal: a cached uuid that misses is re-resolved once

  test "self-heals when the cached home-agenda uuid misses", ctx do
    {prov, mud_ctx} = provision_camillo(ctx)
    :ok = Agenda.append(%{"text" => "pending"}, mud_ctx)
    bot_dir = mint_bot_dir(ctx.store)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets
      )

    pid = Process.whereis(Commonplace.Bots.Dispatcher)

    # Corrupt the cached uuid to simulate a rare re-provision drift.
    :sys.replace_state(pid, fn state ->
      entry = %{state.auto["camillo"] | home_agenda_uuid: UUID.uuid4()}
      %{state | auto: Map.put(state.auto, "camillo", entry)}
    end)

    tick("camillo")

    # The tick self-heals (re-resolves the real agenda) and still sees the
    # non-empty entries → wakes.
    assert_receive {:wake, "camillo", "camillo", event}, 2_000
    assert event["agenda_empty"] == false

    # The cache healed back to the real agenda uuid.
    auto = Dispatcher.registered_autonomous_bots()
    assert auto["camillo"].home_agenda_uuid == prov.agenda_uuid
  end

  ## Unregister

  test "unregister cancels ticks and drops the cache", ctx do
    {_prov, mud_ctx} = provision_camillo(ctx)
    :ok = Agenda.append(%{"text" => "x"}, mud_ctx)
    bot_dir = mint_bot_dir(ctx.store)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets
      )

    :ok = Dispatcher.unregister_autonomous_bot("camillo.bot")
    assert Dispatcher.registered_autonomous_bots() == %{}

    # A queued tick after unregister is a no-op (no wake).
    tick("camillo")
    refute_receive {:wake, _, _, _}, 400
  end

  ## Turn-shape framing (Loop reads the agenda from the home via mud_ctx)

  test "a heartbeat event frames the turn around the home-agenda", ctx do
    {_prov, mud_ctx} = provision_camillo(ctx)
    :ok = Agenda.append(%{"text" => "consolidate the pins"}, mud_ctx)

    {:ok, entity} =
      Commonplace.Bots.Entity.load(ctx.store, mint_bot_dir(ctx.store), "camillo.bot")

    test_pid = self()

    client_fn = fn request ->
      send(test_pid, {:request, request})
      {:ok, %{"stop_reason" => "end_turn", "content" => [], "usage" => %{"output_tokens" => 1}}}
    end

    base_state = %{
      room: "camillo",
      entity: entity,
      mud_ctx: mud_ctx,
      config: %{
        max_calls: 3,
        max_output_tokens: 100,
        max_wall_ms: 5_000,
        model: "test-model",
        fallback_model: nil
      },
      client_fn: client_fn,
      tools_module: Tools,
      signing_context: nil,
      allowlist: [],
      opts: [store: ctx.store]
    }

    assert {:ok, :end_turn} =
             Loop.run(
               Map.put(base_state, :event, %{"kind" => "heartbeat", "thread_quiet" => true})
             )

    assert_receive {:request, hb_request}
    hb_text = first_user_text(hb_request)
    assert hb_text =~ "You woke on a heartbeat"
    assert hb_text =~ "consolidate the pins"
  end

  defp first_user_text(request) do
    request
    |> Map.get(:messages)
    |> List.first()
    |> Map.get("content")
    |> List.first()
    |> Map.get("text")
  end
end
