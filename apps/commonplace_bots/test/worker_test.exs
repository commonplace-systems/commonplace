defmodule Commonplace.Bots.WorkerTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Entity, Worker}
  alias Commonplace.Chat.Messages
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_worker_#{:rand.uniform(1_000_000_000)}")
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

  defp mint_bot_dir(opts) do
    persona = Keyword.get(opts, :persona, "You are alice.")
    trigger = Keyword.get(opts, :trigger, "(?i)@alice\\b")

    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", persona))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", trigger))

    schema =
      case Keyword.get(opts, :bot_config) do
        nil ->
          schema

        config ->
          Schema.add_file(
            schema,
            "bot.json",
            mint_text_doc("bot.json", Jason.encode!(config))
          )
      end

    mint_doc(schema)
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp load_entity(uuid, display_name) do
    {:ok, entity} = Entity.load(CommitStoreClient, uuid, display_name)
    entity
  end

  defp event(text) do
    %{"message_id" => "m1", "author_path" => "human.usr", "text" => text}
  end

  # Stub client that returns the head of a pre-programmed list on
  # each call. The list is held in an Agent keyed by ref so each
  # test gets its own queue.
  defp stub_client(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _request ->
      case Agent.get_and_update(agent, fn
             [] -> {[], []}
             [h | t] -> {h, t}
           end) do
        [] -> {:error, :stub_exhausted}
        response -> {:ok, response}
      end
    end
  end

  defp end_turn(text \\ "ok") do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  defp tool_use(id, name, input) do
    %{
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      ],
      "usage" => %{"output_tokens" => 20}
    }
  end

  describe "run/4 loop mechanics" do
    test "terminates with :end_turn on a single non-tool response" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")

      result =
        Worker.run("demo", entity, event("@alice ping"),
          client_fn: stub_client([end_turn("hi")])
        )

      assert result == {:ok, :end_turn}
    end

    test "dispatches a single tool_use, then ends" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")
      messages_uuid = mint_messages_doc()

      responses = [
        tool_use("t1", "post_message", %{"text" => "hello from alice"}),
        end_turn()
      ]

      result =
        Worker.run("demo", entity, event("@alice say hi"),
          client_fn: stub_client(responses),
          messages_uuid: messages_uuid
        )

      assert result == {:ok, :end_turn}

      {:ok, msgs_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid)
      [entry] = Messages.list(msgs_doc)
      assert entry["text"] == "hello from alice"
      assert entry["author_path"] == "alice.bot"
    end

    test "remember tool appends to memory.jsonl" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")
      messages_uuid = mint_messages_doc()

      responses = [
        tool_use("t1", "remember", %{"text" => "the human likes coffee"}),
        end_turn()
      ]

      result =
        Worker.run("demo", entity, event("@alice remember please"),
          client_fn: stub_client(responses),
          messages_uuid: messages_uuid
        )

      assert result == {:ok, :end_turn}

      {:ok, mem_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, entity.memory_uuid)
      text = ContentType.get_content(mem_doc)
      assert text =~ "the human likes coffee"
      [line] = String.split(text, "\n", trim: true)
      decoded = Jason.decode!(line)
      assert decoded["text"] == "the human likes coffee"
      assert decoded["source_msg_id"] == "m1"
    end

    test "caps :calls when responses keep tool-using past the call budget" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")
      messages_uuid = mint_messages_doc()

      # Endless tool_use loop. With max_calls=2 we should hit
      # {:cap_hit, :calls} after the 2nd call.
      tool_uses = for i <- 1..10, do: tool_use("t#{i}", "post_message", %{"text" => "spam #{i}"})

      result =
        Worker.run("demo", entity, event("@alice spam"),
          client_fn: stub_client(tool_uses),
          messages_uuid: messages_uuid,
          max_calls: 2
        )

      assert result == {:cap_hit, :calls}
    end

    test "caps :max_tokens on stop_reason=\"max_tokens\"" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")

      response = %{
        "stop_reason" => "max_tokens",
        "content" => [],
        "usage" => %{"output_tokens" => 9999}
      }

      result =
        Worker.run("demo", entity, event("@alice"), client_fn: stub_client([response]))

      assert result == {:cap_hit, :max_tokens}
    end

    test "unknown tool returns is_error=true tool_result; loop continues" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")

      # First response uses an unknown tool; second ends the turn.
      responses = [
        tool_use("t1", "bogus_tool", %{}),
        end_turn()
      ]

      assert {:ok, :end_turn} =
               Worker.run("demo", entity, event("@alice"),
                 client_fn: stub_client(responses)
               )
    end

    test "client failure terminates with :error" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")

      result =
        Worker.run("demo", entity, event("@alice"),
          client_fn: fn _ -> {:error, :boom} end
        )

      assert {:error, {:client_failure, :boom}} = result
    end

    test "bot.json max_calls overrides default" do
      bot = mint_bot_dir(bot_config: %{"max_calls" => 1})
      entity = load_entity(bot, "alice.bot")
      messages_uuid = mint_messages_doc()

      # Two tool_uses queued; the second should never be reached.
      responses = [
        tool_use("t1", "post_message", %{"text" => "first"}),
        tool_use("t2", "post_message", %{"text" => "second"})
      ]

      result =
        Worker.run("demo", entity, event("@alice"),
          client_fn: stub_client(responses),
          messages_uuid: messages_uuid
        )

      assert result == {:cap_hit, :calls}
    end
  end
end
