defmodule Commonplace.Bots.DispatcherTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Dispatcher
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_dispatcher_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    # Restart dispatcher with an in-test worker_hook that pushes to the
    # current test pid.
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
           [worker_hook: hook, rate_limit_enabled: false]},
          id: Commonplace.Bots.Dispatcher
        )
      )

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

      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_doc(doc) do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_text_doc(name, body) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    mint_doc(doc)
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_bot_dir(persona, trigger) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", persona))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", trigger))

    mint_doc(schema)
  end

  defp mint_room_dir(bots) do
    schema =
      Enum.reduce(bots, Schema.new_schema(), fn {name, dir_uuid}, acc ->
        Schema.add_directory(acc, name, dir_uuid)
      end)

    mint_doc(schema)
  end

  defp post(room, messages_uuid, text, author_path \\ "human.usr") do
    Actions.post_message(messages_uuid, text,
      room: room,
      signer_id: "test-signer",
      author_path: author_path
    )
  end

  describe "subscribe_room/3" do
    test "registers a room and accepts re-registration" do
      :ok = Dispatcher.subscribe_room("alpha", "dir-1", "msg-1")
      assert Map.has_key?(Dispatcher.registered_rooms(), "alpha")

      :ok = Dispatcher.subscribe_room("alpha", "dir-1", "msg-1")
      assert Map.has_key?(Dispatcher.registered_rooms(), "alpha")
    end

    test "unsubscribe_room/1 drops the registration" do
      :ok = Dispatcher.subscribe_room("beta", "dir-2", "msg-2")
      :ok = Dispatcher.unsubscribe_room("beta")
      refute Map.has_key?(Dispatcher.registered_rooms(), "beta")
    end
  end

  describe "chat event routing" do
    test "human-authored post triggers matching bot's worker_hook" do
      alice = mint_bot_dir("I am alice.", "(?i)@alice\\b")
      room_uuid = mint_room_dir([{"alice.bot", alice}])
      messages_uuid = mint_messages_doc()

      :ok = Dispatcher.subscribe_room("demo", room_uuid, messages_uuid)

      {:ok, _} = post("demo", messages_uuid, "Hey @alice, ping")

      assert_receive {:wake, "demo", "alice", event}, 1_000
      assert event["text"] == "Hey @alice, ping"
      assert event["verb"] == "post"
      assert event["room"] == "demo"
    end

    test "non-matching text does not trigger" do
      alice = mint_bot_dir("I am alice.", "(?i)@alice\\b")
      room_uuid = mint_room_dir([{"alice.bot", alice}])
      messages_uuid = mint_messages_doc()

      :ok = Dispatcher.subscribe_room("demo2", room_uuid, messages_uuid)

      {:ok, _} = post("demo2", messages_uuid, "no mention here")

      refute_receive {:wake, _, _, _}, 250
    end

    test "bot-authored post does NOT trigger another bot (loop prevention)" do
      alice = mint_bot_dir("I am alice.", "(?i)hello")
      bob = mint_bot_dir("I am bob.", "(?i)hello")

      room_uuid = mint_room_dir([{"alice.bot", alice}, {"bob.bot", bob}])
      messages_uuid = mint_messages_doc()

      :ok = Dispatcher.subscribe_room("demo3", room_uuid, messages_uuid)

      {:ok, _} = post("demo3", messages_uuid, "hello room", "alice.bot")

      refute_receive {:wake, _, _, _}, 250
    end

    test "multiple bots whose triggers match each get a wake" do
      alice = mint_bot_dir("I am alice.", "(?i)everyone")
      bob = mint_bot_dir("I am bob.", "(?i)everyone")

      room_uuid = mint_room_dir([{"alice.bot", alice}, {"bob.bot", bob}])
      messages_uuid = mint_messages_doc()

      :ok = Dispatcher.subscribe_room("demo4", room_uuid, messages_uuid)

      {:ok, _} = post("demo4", messages_uuid, "hello everyone")

      assert_receive {:wake, "demo4", name_a, _}, 1_000
      assert_receive {:wake, "demo4", name_b, _}, 1_000
      assert Enum.sort([name_a, name_b]) == ["alice", "bob"]
    end

    test "production default (worker_hook=nil) spawns a Worker via spawn_worker" do
      # Restart dispatcher without a worker_hook — exercises the
      # production default path (Dispatcher.spawn_worker/4 with the
      # registered room's messages_uuid).
      bots_sup = Commonplace.Bots.Supervisor
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, [rate_limit_enabled: false]},
            id: Commonplace.Bots.Dispatcher
          )
        )

      test_pid = self()

      :telemetry.attach(
        "worker-started-#{:rand.uniform(1_000_000)}",
        [:commonplace, :bots, :worker, :started],
        fn _e, _meas, meta, _cfg -> send(test_pid, {:worker_started, meta}) end,
        nil
      )

      alice = mint_bot_dir("I am alice.", "(?i)@alice\\b")
      room_uuid = mint_room_dir([{"alice.bot", alice}])
      messages_uuid = mint_messages_doc()

      :ok = Dispatcher.subscribe_room("prod-default", room_uuid, messages_uuid)
      {:ok, _} = post("prod-default", messages_uuid, "@alice ping")

      assert_receive {:worker_started, %{bot: "alice", room: "prod-default"}}, 1_500
    end

    test "unregistered room receives no events even if posts happen" do
      alice = mint_bot_dir("I am alice.", "(?i)@alice\\b")
      _room_uuid = mint_room_dir([{"alice.bot", alice}])
      messages_uuid = mint_messages_doc()

      # Note: NOT calling subscribe_room/3 for "ghost-room".

      {:ok, _} = post("ghost-room", messages_uuid, "@alice ping")

      refute_receive {:wake, _, _, _}, 250
    end
  end
end
