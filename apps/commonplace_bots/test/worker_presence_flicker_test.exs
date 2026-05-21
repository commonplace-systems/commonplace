defmodule Commonplace.Bots.Worker.PresenceFlickerTest do
  @moduledoc """
  CX-q8nk(1): .exe presence flicker — Worker.run registers a
  unique honorific `.exe` entry under the bot's directory while
  the cave-diver loop runs, and removes it on exit (success,
  cap, error, crash).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Entity, Worker}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_presence_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
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

  defp mint_bot_dir do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "I am alice."))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", "(?i)@alice"))

    mint_doc(schema)
  end

  defp load_entity(uuid), do: elem(Entity.load(CommitStoreClient, uuid, "alice.bot"), 1)

  defp list_dir_names(uuid) do
    Commonplace.Tree.DocCache.clear()
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid)
    Schema.list_entries(doc) |> Enum.map(& &1.name)
  end

  defp end_turn do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "ok"}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  test ".exe is registered under bot dir during run, removed after" do
    bot = mint_bot_dir()
    entity = load_entity(bot)
    test_pid = self()

    client = fn _req ->
      send(test_pid, {:during_run, list_dir_names(entity.dir_uuid)})
      {:ok, end_turn()}
    end

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "hi"}, client_fn: client)

    assert result == {:ok, :end_turn}

    assert_receive {:during_run, names_during}, 1_000
    exe_names = Enum.filter(names_during, &String.ends_with?(&1, ".exe"))
    assert length(exe_names) == 1
    [exe] = exe_names
    assert String.starts_with?(exe, "alice-")

    names_after = list_dir_names(entity.dir_uuid)
    refute Enum.any?(names_after, &String.ends_with?(&1, ".exe"))
  end

  test "presence_enabled=false skips both register and remove" do
    bot = mint_bot_dir()
    entity = load_entity(bot)
    test_pid = self()

    client = fn _req ->
      send(test_pid, {:during_run, list_dir_names(entity.dir_uuid)})
      {:ok, end_turn()}
    end

    Worker.run("demo", entity, %{"message_id" => "m1", "text" => "hi"},
      client_fn: client,
      presence_enabled: false
    )

    assert_receive {:during_run, names}, 1_000
    refute Enum.any?(names, &String.ends_with?(&1, ".exe"))
  end

  test "cap-hit outcome still cleans up .exe" do
    bot = mint_bot_dir()
    entity = load_entity(bot)
    test_pid = self()

    tool_use = %{
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "tool_use", "id" => "t1", "name" => "post_message", "input" => %{"text" => "x"}}
      ],
      "usage" => %{"output_tokens" => 10}
    }

    client = fn _req ->
      send(test_pid, {:during_run, list_dir_names(entity.dir_uuid)})
      {:ok, tool_use}
    end

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "spam"},
        client_fn: client,
        messages_uuid: mint_messages_doc(),
        max_calls: 1
      )

    assert result == {:cap_hit, :calls}

    assert_receive {:during_run, names_during}, 1_000
    assert Enum.any?(names_during, &String.ends_with?(&1, ".exe"))

    names_after = list_dir_names(entity.dir_uuid)
    refute Enum.any?(names_after, &String.ends_with?(&1, ".exe"))
  end

  test "client error still cleans up .exe" do
    bot = mint_bot_dir()
    entity = load_entity(bot)

    {:error, _} =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "boom"},
        client_fn: fn _ -> {:error, :boom} end
      )

    names = list_dir_names(entity.dir_uuid)
    refute Enum.any?(names, &String.ends_with?(&1, ".exe"))
  end

  test "concurrent workers from same bot get distinct .exe names" do
    bot = mint_bot_dir()
    entity = load_entity(bot)
    test_pid = self()

    # Each worker emits the dir state inside its API call, blocks on
    # receive, then completes. We hold both inside their loop
    # simultaneously to verify the dir contains TWO .exe entries.
    client_factory = fn label ->
      fn _req ->
        send(test_pid, {label, list_dir_names(entity.dir_uuid)})

        receive do
          :go -> :ok
        after
          2_000 -> :ok
        end

        {:ok, end_turn()}
      end
    end

    t1 =
      Task.async(fn ->
        Worker.run("demo", entity, %{"message_id" => "m1", "text" => "ping"},
          client_fn: client_factory.(:a)
        )
      end)

    # Wait for W1's Presence.create to land before starting W2, so the
    # two `.exe` entries land sequentially via chained commits. After
    # this point both workers are parked inside their client_fn with
    # both `.exe` files present in the dir.
    assert_receive {:a, _}, 1_000

    t2 =
      Task.async(fn ->
        Worker.run("demo", entity, %{"message_id" => "m2", "text" => "ping"},
          client_fn: client_factory.(:b)
        )
      end)

    assert_receive {:b, names}, 1_000

    exes = Enum.filter(names, &String.ends_with?(&1, ".exe"))
    assert length(exes) == 2, "expected 2 concurrent .exe entries, saw: #{inspect(names)}"
    assert Enum.uniq(exes) |> length() == 2

    # Release both workers and let them finish. We don't assert on
    # the final dir state here — concurrent Presence.remove against
    # the same parent schema can race (both reload, both write
    # deletes via concurrent chained commits) and leave one orphan
    # entry until the next worker reaps. The single-worker cleanup
    # path is covered above; this test exclusively verifies
    # distinct-name registration during overlap.
    send(t1.pid, :go)
    send(t2.pid, :go)
    _ = Task.await(t1)
    _ = Task.await(t2)
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Commonplace.Chat.Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end
end
