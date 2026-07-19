defmodule Commonplace.Bots.EndToEndTest do
  @moduledoc """
  Phase-7 acceptance test for the v0 chat-room bot build (CX-57w3).

  Goal: prove the full pipeline end-to-end, with the substrate
  doing the real work, using a stub Anthropic client so the test
  is hermetic (no API key, no network).

  Pipeline under test:

      human posts via Chat.Actions
        → magenta chat:<room>:events broadcast
        → Bots.Dispatcher subscribed → loads message text
        → enumerates *.bot/ children
        → Bots.Trigger.Regex matches
        → Bots.RateLimit.acquire :ok
        → Bots.Activity logs "fired"
        → Bots.Dispatcher.spawn_worker → supervised Task
        → Bots.Worker.run → cave-diver loop
        → stub client returns tool_use(post_message) + end_turn
        → Chat.Actions.post_message lands the bot's reply
        → release on Task exit

  The acceptance criterion from boss-clod:
    "human types something → bot wakes → posts → optionally
     remembers → exits."

  This test covers all four verbs.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Activity, Demo, Dispatcher}
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_e2e_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    store_sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(store_sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(store_sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(store_sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    bots_sup = Commonplace.Bots.Supervisor

    # Fresh RateLimit
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.RateLimit)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.RateLimit)
    {:ok, _pid} = Supervisor.start_child(bots_sup, Commonplace.Bots.RateLimit)

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, []},
            id: Commonplace.Bots.Dispatcher
          )
        )

      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.RateLimit)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.RateLimit)
      {:ok, _pid} = Supervisor.start_child(bots_sup, Commonplace.Bots.RateLimit)

      _ = Supervisor.terminate_child(store_sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(store_sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(
          store_sup,
          {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"}
        )

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    # Camillo C1: an isolated SecretStore so workers can resolve a REAL
    # per-bot signing context (their posts/remembers are genuinely signed)
    # without touching the app's global key custody.
    secrets_dir =
      Path.join(System.tmp_dir!(), "cp_bots_e2e_secrets_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(secrets_dir)
    secrets = :"cp_bots_e2e_secrets_#{:rand.uniform(1_000_000_000)}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(secrets_dir)
    end)

    %{secrets: secrets}
  end

  defp restart_dispatcher_with(opts) do
    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec({Commonplace.Bots.Dispatcher, opts},
          id: Commonplace.Bots.Dispatcher
        )
      )
  end

  defp mint_root do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp wait_for(fun, timeout_ms \\ 2_000, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline, interval_ms)
  end

  defp do_wait(fun, deadline, interval_ms) do
    case fun.() do
      true ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval_ms)
          do_wait(fun, deadline, interval_ms)
        end
    end
  end

  defp stub_client(scripts) do
    # scripts: %{bot_name => [response, response, …]}
    {:ok, agent} = Agent.start_link(fn -> scripts end)

    fn request ->
      sys = Map.get(request, :system, "")
      bot = which_bot(sys)

      response =
        Agent.get_and_update(agent, fn state ->
          case Map.get(state, bot) do
            [h | t] -> {h, Map.put(state, bot, t)}
            _ -> {:exhausted, state}
          end
        end)

      case response do
        :exhausted -> {:ok, end_turn("(no script left)")}
        r -> {:ok, r}
      end
    end
  end

  defp which_bot(system) when is_binary(system) do
    cond do
      String.contains?(system, "Alice") -> "alice"
      String.contains?(system, "Bob") -> "bob"
      true -> "unknown"
    end
  end

  defp end_turn(text) do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  defp tool_use(id, name, input) do
    %{
      "stop_reason" => "tool_use",
      "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
      "usage" => %{"output_tokens" => 20}
    }
  end

  defp read_messages(messages_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid)
    Messages.materialize(doc)
  end

  defp read_text(uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid)
    ContentType.get_content(doc) || ""
  end

  test "ACCEPTANCE: human posts @alice → alice wakes, posts, remembers, exits", %{secrets: secrets} do
    root = mint_root()
    demo = Demo.bootstrap(root)

    scripts = %{
      "alice" => [
        tool_use("t1", "post_message", %{"text" => "hi human, what's up?"}),
        tool_use("t2", "remember", %{"text" => "human said hello at sundown"}),
        end_turn("done")
      ]
    }

    client_fn = stub_client(scripts)

    worker_hook = fn room, entity, event ->
      Dispatcher.spawn_worker(room, entity, event,
        client_fn: client_fn,
        messages_uuid: demo.messages_uuid,
        root_uuid: root,
        secret_store: secrets
      )
    end

    restart_dispatcher_with(worker_hook: worker_hook, rate_limit_enabled: true)
    :ok = Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)

    {:ok, %{message_id: human_msg_id}} =
      Actions.post_message(demo.messages_uuid, "hey @alice you there?",
        room: demo.room,
        signer_id: "test-human",
        author_path: "human.usr"
      )

    # Wait for alice's post to land in _messages.
    :ok =
      wait_for(fn ->
        entries = read_messages(demo.messages_uuid)
        Enum.any?(entries, fn e -> Map.get(e, "author_path") == "alice.bot" end)
      end)

    entries = read_messages(demo.messages_uuid)

    [human, alice_msg] =
      Enum.sort_by(entries, fn _ -> 0 end) |> Enum.take(2) |> Enum.sort_by(fn e -> e["ts"] end)

    assert human["text"] == "hey @alice you there?"
    assert human["author_path"] == "human.usr"
    assert human["id"] == human_msg_id

    assert alice_msg["text"] == "hi human, what's up?"
    assert alice_msg["author_path"] == "alice.bot"

    # Wait for the remember tool to settle.
    alice_uuid = demo.bots["alice"]
    {:ok, alice_entity} = Commonplace.Bots.Entity.load(CommitStoreClient, alice_uuid, "alice.bot")

    :ok =
      wait_for(fn ->
        text = read_text(alice_entity.memory_uuid)
        String.contains?(text, "human said hello at sundown")
      end)

    text = read_text(alice_entity.memory_uuid)
    [line] = String.split(text, "\n", trim: true)
    decoded = Jason.decode!(line)
    assert decoded["text"] == "human said hello at sundown"
    assert decoded["source_msg_id"] == human_msg_id

    # __bot_activity should have a "fired" entry for alice.
    activity_uuid = Dispatcher.registered_rooms()[demo.room].activity_uuid

    :ok =
      wait_for(fn ->
        entries = Activity.list(activity_uuid, CommitStoreClient)
        Enum.any?(entries, fn e -> e["decision"] == "fired" and e["bot"] == "alice" end)
      end)
  end

  test "ACCEPTANCE: multi-bot room, both bots fire on their own mentions independently", %{
    secrets: secrets
  } do
    root = mint_root()
    demo = Demo.bootstrap(root)

    scripts = %{
      "alice" => [tool_use("t1", "post_message", %{"text" => "alice here"}), end_turn("ok")],
      "bob" => [tool_use("t1", "post_message", %{"text" => "yo"}), end_turn("ok")]
    }

    client_fn = stub_client(scripts)

    worker_hook = fn room, entity, event ->
      Dispatcher.spawn_worker(room, entity, event,
        client_fn: client_fn,
        messages_uuid: demo.messages_uuid,
        root_uuid: root,
        secret_store: secrets
      )
    end

    restart_dispatcher_with(worker_hook: worker_hook, rate_limit_enabled: true)
    :ok = Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)

    Actions.post_message(demo.messages_uuid, "yo @alice",
      room: demo.room,
      signer_id: "test-human",
      author_path: "human.usr"
    )

    :ok =
      wait_for(fn ->
        entries = read_messages(demo.messages_uuid)
        Enum.any?(entries, fn e -> e["author_path"] == "alice.bot" end)
      end)

    Actions.post_message(demo.messages_uuid, "yo @bob",
      room: demo.room,
      signer_id: "test-human",
      author_path: "human.usr"
    )

    :ok =
      wait_for(fn ->
        entries = read_messages(demo.messages_uuid)
        Enum.any?(entries, fn e -> e["author_path"] == "bob.bot" end)
      end)

    entries = read_messages(demo.messages_uuid)
    texts = Enum.map(entries, & &1["text"])
    assert "alice here" in texts
    assert "yo" in texts
    assert "yo @alice" in texts
    assert "yo @bob" in texts
  end

  test "ACCEPTANCE: bot does NOT reply to another bot (loop prevention end-to-end)" do
    root = mint_root()
    demo = Demo.bootstrap(root)

    scripts = %{"alice" => [end_turn("hi")], "bob" => [end_turn("hi")]}
    client_fn = stub_client(scripts)

    worker_hook = fn room, entity, event ->
      Dispatcher.spawn_worker(room, entity, event,
        client_fn: client_fn,
        messages_uuid: demo.messages_uuid
      )
    end

    restart_dispatcher_with(worker_hook: worker_hook, rate_limit_enabled: false)
    :ok = Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)

    # Bot-authored post mentioning the other bot — should not fire.
    Actions.post_message(demo.messages_uuid, "yo @bob",
      room: demo.room,
      signer_id: "bot:alice",
      author_path: "alice.bot"
    )

    Process.sleep(300)

    entries = read_messages(demo.messages_uuid)
    refute Enum.any?(entries, fn e -> e["author_path"] == "bob.bot" end)
  end
end
