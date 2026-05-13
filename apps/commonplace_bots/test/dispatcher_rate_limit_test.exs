defmodule Commonplace.Bots.DispatcherRateLimitTest do
  @moduledoc """
  Integration tests for the dispatcher's rate-limit + activity-log
  paths. Driven with a synchronous worker_hook that records wakes
  into the test pid's mailbox but does NOT call RateLimit.release —
  so per-room/global concurrency caps are observable from the
  outside.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Activity, Dispatcher, RateLimit}
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_disp_rl_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    store_sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(store_sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(store_sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(store_sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    bots_sup = Commonplace.Bots.Supervisor

    # Reset RateLimit
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.RateLimit)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.RateLimit)
    {:ok, _pid} = Supervisor.start_child(bots_sup, Commonplace.Bots.RateLimit)

    # Restart dispatcher with rate-limit enabled + recording hook.
    test_pid = self()
    hook = fn room, entity, event -> send(test_pid, {:wake, room, entity.name, event}) end

    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Commonplace.Bots.Dispatcher,
           [worker_hook: hook, rate_limit_enabled: true]},
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

  defp mint_bot_dir(trigger) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "p"))
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

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp post(room, uuid, text, author \\ "human.usr") do
    Actions.post_message(uuid, text, room: room, signer_id: "sig", author_path: author)
  end

  test "ensure_doc minted under the room on subscribe" do
    alice = mint_bot_dir("(?i)@alice")
    room = mint_room_dir([{"alice.bot", alice}])
    messages = mint_messages_doc()

    :ok = Dispatcher.subscribe_room("demo", room, messages)

    rooms = Dispatcher.registered_rooms()
    assert is_binary(rooms["demo"].activity_uuid)
  end

  test "fired trigger appends a 'fired' entry to __bot_activity" do
    alice = mint_bot_dir("(?i)@alice")
    room = mint_room_dir([{"alice.bot", alice}])
    messages = mint_messages_doc()

    :ok = Dispatcher.subscribe_room("demo", room, messages)
    {:ok, _} = post("demo", messages, "@alice ping")

    assert_receive {:wake, "demo", "alice", _}, 1_000

    # Give the Task.start activity-log writer a moment to settle.
    Process.sleep(150)

    activity_uuid = Dispatcher.registered_rooms()["demo"].activity_uuid
    entries = Activity.list(activity_uuid, CommitStoreClient)
    assert Enum.any?(entries, fn e -> e["decision"] == "fired" and e["bot"] == "alice" end)
  end

  test "rate-limit suppression appends a 'suppressed' entry, no wake" do
    alice = mint_bot_dir("(?i)@alice")
    room = mint_room_dir([{"alice.bot", alice}])
    messages = mint_messages_doc()

    :ok = Dispatcher.subscribe_room("demo", room, messages)

    # Tighten room concurrency so a single acquire saturates and
    # the second event suppresses (the test hook doesn't release).
    :ok = RateLimit.config(per_room_concurrency: 1, global_concurrency: 100)

    {:ok, _} = post("demo", messages, "@alice ping 1")
    assert_receive {:wake, "demo", "alice", _}, 1_000

    {:ok, _} = post("demo", messages, "@alice ping 2")
    refute_receive {:wake, _, _, _}, 250

    Process.sleep(150)

    activity_uuid = Dispatcher.registered_rooms()["demo"].activity_uuid
    entries = Activity.list(activity_uuid, CommitStoreClient)

    assert Enum.any?(entries, fn e ->
             e["decision"] == "suppressed" and e["reason"] == "room_concurrency"
           end)
  end
end
