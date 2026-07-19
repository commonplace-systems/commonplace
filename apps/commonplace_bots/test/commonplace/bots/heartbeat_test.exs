defmodule Commonplace.Bots.HeartbeatTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Agenda, Dispatcher, Entity}
  alias Commonplace.Bots.Worker.{Loop, Tools}
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Document.ContentType
  alias Commonplace.Presence
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_heartbeat_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    test_pid = self()
    hook = fn room, entity, event -> send(test_pid, {:wake, room, entity.name, event}) end

    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Commonplace.Bots.Dispatcher, [worker_hook: hook, rate_limit_enabled: false]},
          id: Commonplace.Bots.Dispatcher
        )
      )

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

      # The dispatcher is now stopped, so no further heartbeat ticks fire.
      # Let any in-flight best-effort log_activity tasks drain against the
      # still-alive store before we tear it down (teardown-race noise only).
      Process.sleep(100)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, []},
            id: Commonplace.Bots.Dispatcher
          )
        )

      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  ## Fixtures

  defp mint_doc(doc) do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_text_doc(name, body) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    mint_doc(doc)
  end

  # opts: [heartbeat_ms: int | nil, trigger: string]
  defp mint_bot_dir(opts) do
    trigger = Keyword.get(opts, :trigger, "(?i)@alice\\b")

    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "I am alice."))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", trigger))

    schema =
      case Keyword.get(opts, :heartbeat_ms) do
        ms when is_integer(ms) ->
          Schema.add_file(
            schema,
            "bot.json",
            mint_text_doc("bot.json", Jason.encode!(%{"heartbeat_ms" => ms}))
          )

        _ ->
          schema
      end

    mint_doc(schema)
  end

  defp mint_room_dir(bots) do
    schema =
      Enum.reduce(bots, Schema.new_schema(), fn {name, dir_uuid}, acc ->
        Schema.add_directory(acc, name, dir_uuid)
      end)

    mint_doc(schema)
  end

  defp mint_messages_doc(entries \\ []) do
    doc =
      Enum.reduce(entries, Messages.new(), fn entry, acc ->
        Messages.append(acc, entry)
      end)

    mint_doc(doc)
  end

  ## Opt-in

  test "a bot with no heartbeat_ms gets no tick (even with a non-empty agenda)" do
    dir = mint_bot_dir(heartbeat_ms: nil)
    room_uuid = mint_room_dir([{"alice.bot", dir}])
    messages_uuid = mint_messages_doc()

    # Give the bot a non-empty agenda so the ONLY reason it doesn't wake
    # is the missing heartbeat_ms opt-in, not an empty agenda.
    {:ok, entity} = Entity.load(CommitStoreClient, dir, "alice.bot")
    :ok = Agenda.append(entity, %{"text" => "pending work"}, CommitStoreClient)

    :ok = Dispatcher.subscribe_room("optin-off", room_uuid, messages_uuid)

    refute_receive {:wake, _, _, _}, 400
  end

  test "a bot with a positive heartbeat_ms fires a tick reaching evaluate_and_dispatch" do
    dir = mint_bot_dir(heartbeat_ms: 50)
    room_uuid = mint_room_dir([{"alice.bot", dir}])
    messages_uuid = mint_messages_doc()

    # Non-empty agenda → the heartbeat trigger wakes.
    {:ok, entity} = Entity.load(CommitStoreClient, dir, "alice.bot")
    :ok = Agenda.append(entity, %{"text" => "do a thing"}, CommitStoreClient)

    :ok = Dispatcher.subscribe_room("optin-on", room_uuid, messages_uuid)

    assert_receive {:wake, "optin-on", "alice", event}, 2_000
    # The event is the internally-tagged heartbeat, not a chat post.
    assert event["kind"] == "heartbeat"
    assert event["verb"] == "heartbeat"
  end

  ## Wake vs skip

  test "wake when the agenda is non-empty (thread quiet)" do
    dir = mint_bot_dir(heartbeat_ms: 50)
    room_uuid = mint_room_dir([{"alice.bot", dir}])
    messages_uuid = mint_messages_doc()

    {:ok, entity} = Entity.load(CommitStoreClient, dir, "alice.bot")
    :ok = Agenda.append(entity, %{"text" => "unfiled pin"}, CommitStoreClient)

    :ok = Dispatcher.subscribe_room("wake-agenda", room_uuid, messages_uuid)

    assert_receive {:wake, "wake-agenda", "alice", event}, 2_000
    assert event["kind"] == "heartbeat"
    assert event["agenda_empty"] == false
  end

  test "wake when the thread is active (empty agenda)" do
    dir = mint_bot_dir(heartbeat_ms: 50)
    room_uuid = mint_room_dir([{"alice.bot", dir}])

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    messages_uuid =
      mint_messages_doc([
        %{"id" => UUID.uuid4(), "text" => "fresh chatter", "author_path" => "human.usr", "ts" => now}
      ])

    :ok = Dispatcher.subscribe_room("wake-active", room_uuid, messages_uuid)

    assert_receive {:wake, "wake-active", "alice", event}, 2_000
    assert event["kind"] == "heartbeat"
    assert event["agenda_empty"] == true
    assert event["thread_quiet"] == false
  end

  test "skip when the agenda is empty AND the thread is quiet — but presence STILL beats" do
    dir = mint_bot_dir(heartbeat_ms: 50)
    room_uuid = mint_room_dir([{"alice.bot", dir}])
    # Empty messages doc → quiet thread.
    messages_uuid = mint_messages_doc()

    # A .usr presence for the bot in the room dir, to observe the keep-alive.
    {:ok, presence_uuid} = Presence.create("alice", :usr, room_uuid, CommitStore)
    ts0 = Presence.read(presence_uuid, CommitStoreClient)["heartbeat"]
    assert is_binary(ts0)

    :ok = Dispatcher.subscribe_room("skip-quiet", room_uuid, messages_uuid)

    # Over this window several ticks fire; each MUST skip (no worker) yet
    # STILL beat the presence.
    refute_receive {:wake, _, _, _}, 400

    ts1 = Presence.read(presence_uuid, CommitStoreClient)["heartbeat"]
    assert is_binary(ts1)
    assert ts1 != ts0, "a :skip tick must still refresh the bot's presence heartbeat"
  end

  # The pin above proves the tick BEATS on skip, but in the permissive test
  # store an unsigned beat lands regardless. This one proves the beat under
  # REAL enforce — the regime the requirement exists for (cp-plan #8716). The
  # keep-alive is NODE-signed (a runtime fact, not a Camillo turn): an OLD
  # unsigned beat is DENIED under enforce → the presence never advances → the
  # reaper takes a resting bot; the node-signed beat LANDS.
  test "under enforce the keep-alive beat must be NODE-signed to land (unsigned is denied)" do
    node_ctx =
      case NodeIdentity.signing_context() do
        {:ok, ctx} -> ctx
        other -> flunk("test needs a node signing context, got: #{inspect(other)}")
      end

    prior_gate = Application.get_env(:commonplace, :local_write_gate)
    prior_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{node_ctx.identity_uuid => Signing.encode_key(node_ctx.public_key)}
    })

    on_exit(fn ->
      case prior_gate do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      case prior_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end
    end)

    # Node-signed parent dir + .usr presence (unsigned would be denied here).
    parent = UUID.uuid4()

    CommitStore.create_commit(
      CommitStore,
      parent,
      Yelixer.Encoding.encode_update(Schema.new_schema()),
      nil,
      %{},
      signing_context: node_ctx
    )

    {:ok, presence_uuid} =
      Presence.create("resting-bot", :usr, parent, CommitStore, signing_context: node_ctx)

    ts0 = Presence.read(presence_uuid, CommitStoreClient)["heartbeat"]
    assert is_binary(ts0)

    # The OLD unsigned beat: DENIED under enforce → presence does NOT advance.
    Presence.heartbeat(presence_uuid, CommitStore)
    Commonplace.Tree.DocCache.clear()

    assert Presence.read(presence_uuid, CommitStoreClient)["heartbeat"] == ts0,
           "an unsigned keep-alive beat must NOT land under enforce (this is the bug the fix closes)"

    # The fix: a NODE-signed beat (what `beat_presence/4` now does via
    # `state.node_ctx`) LANDS, keeping the resting bot alive.
    Process.sleep(2)
    Presence.heartbeat(presence_uuid, CommitStore, signing_context: node_ctx)
    Commonplace.Tree.DocCache.clear()

    ts1 = Presence.read(presence_uuid, CommitStoreClient)["heartbeat"]
    assert is_binary(ts1)

    assert ts1 != ts0,
           "a node-signed keep-alive beat MUST land under enforce (keeps the resting bot alive)"
  end

  ## Unspoofable-by-chat

  test "a chat payload crafted to look like a heartbeat still routes as a normal post" do
    dir = mint_bot_dir(trigger: "(?i)heartbeat")
    room_uuid = mint_room_dir([{"alice.bot", dir}])

    mid = UUID.uuid4()

    messages_uuid =
      mint_messages_doc([
        %{"id" => mid, "text" => "heartbeat now", "author_path" => "human.usr",
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()}
      ])

    :ok = Dispatcher.subscribe_room("spoof", room_uuid, messages_uuid)

    pid = Process.whereis(Commonplace.Bots.Dispatcher)

    # A chat event whose payload smuggles a "kind" => "heartbeat" field.
    # It must NEVER produce a heartbeat turn — the chat path always yields
    # verb "post" and strips any "kind".
    send(
      pid,
      {:magenta, "magenta:chat:spoof:events",
       %{
         type: "post",
         payload: %{
           "author_path" => "human.usr",
           "room" => "spoof",
           "message_id" => mid,
           "kind" => "heartbeat"
         }
       }}
    )

    assert_receive {:wake, "spoof", "alice", event}, 2_000
    assert event["verb"] == "post"
    refute Map.get(event, "kind") == "heartbeat"
  end

  ## Turn shape (Loop.build_initial_user_text via Loop.run)

  test "a heartbeat event frames the turn around the agenda, not the chat shape" do
    agenda_line =
      Jason.encode!(%{"ts" => "2026-01-01T00:00:00Z", "text" => "consolidate the pins"}) <> "\n"

    agenda_uuid = mint_text_doc("agenda.jsonl", agenda_line)

    entity = %Entity{
      name: "alice",
      dir_uuid: UUID.uuid4(),
      persona: "You are alice.",
      memory_uuid: nil,
      trigger_source: "",
      trigger_kind: :regex,
      bot_config: %{},
      children: %{"agenda.jsonl" => agenda_uuid}
    }

    test_pid = self()

    client_fn = fn request ->
      send(test_pid, {:request, request})
      {:ok, %{"stop_reason" => "end_turn", "content" => [], "usage" => %{"output_tokens" => 1}}}
    end

    base_state = %{
      room: "room",
      entity: entity,
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
      opts: [store: CommitStoreClient]
    }

    # Heartbeat event → heartbeat shape.
    assert {:ok, :end_turn} =
             Loop.run(Map.put(base_state, :event, %{"kind" => "heartbeat", "thread_quiet" => true}))

    assert_receive {:request, hb_request}
    hb_text = first_user_text(hb_request)
    assert hb_text =~ "You woke on a heartbeat"
    assert hb_text =~ "consolidate the pins"
    assert hb_text =~ "quiet"
    refute hb_text =~ "New message in"

    # A normal chat event → chat shape (unchanged).
    assert {:ok, :end_turn} =
             Loop.run(Map.put(base_state, :event, %{"author_path" => "bob.usr", "text" => "hi"}))

    assert_receive {:request, chat_request}
    chat_text = first_user_text(chat_request)
    assert chat_text =~ "New message in"
    refute chat_text =~ "You woke on a heartbeat"
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
