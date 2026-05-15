defmodule Commonplace.Bots.Worker.FallbackTest do
  @moduledoc """
  CX-hl7j: prove the worker auto-falls-back to a secondary model
  on retryable Anthropic errors (529 Overloaded / 503 Service
  Unavailable / 502 Bad Gateway), and that bot.json `fallback_model`
  overrides the default.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Entity, Worker}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_fallback_#{:rand.uniform(1_000_000_000)}")
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

  defp mint_bot(opts) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "I am alice."))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", "(?i)@alice"))

    schema =
      case Keyword.get(opts, :bot_config) do
        nil ->
          schema

        cfg ->
          Schema.add_file(
            schema,
            "bot.json",
            mint_text_doc("bot.json", Jason.encode!(cfg))
          )
      end

    mint_doc(schema)
  end

  defp load_entity(uuid), do: elem(Entity.load(CommitStoreClient, uuid, "alice.bot"), 1)

  defp end_turn do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "ok"}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  defp overload do
    {:error,
     {:http_status, 529, %{"error" => %{"message" => "Overloaded", "type" => "overloaded_error"}}}}
  end

  # The client sends `{:request, model}` to the *test* pid for
  # assertion. The Agent only stores the response queue.
  defp model_tracking_client(queue_agent, test_pid, scripts) do
    fn request ->
      send(test_pid, {:request, request.model})

      script =
        Agent.get_and_update(queue_agent, fn s ->
          case Map.get(s, :queue, []) do
            [h | t] -> {h, Map.put(s, :queue, t)}
            _ -> {:exhausted, s}
          end
        end)

      _ = scripts

      case script do
        :exhausted -> {:ok, end_turn()}
        :overload -> overload()
        response -> {:ok, response}
      end
    end
  end

  defp start_call_log(scripts) do
    {:ok, pid} = Agent.start_link(fn -> %{queue: scripts} end)
    pid
  end

  test "529 → fallback to Haiku, second call uses fallback model, succeeds" do
    bot = mint_bot([])
    entity = load_entity(bot)

    log = start_call_log([:overload, end_turn()])
    client = model_tracking_client(log, self(), nil)

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "@alice ping"},
        client_fn: client,
        model: "claude-sonnet-4-6",
        fallback_model: "claude-haiku-4-5-20251001"
      )

    assert result == {:ok, :end_turn}

    requests = collect_models(log)
    assert requests == ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
  end

  test "bot.json fallback_model override is honored" do
    bot = mint_bot(bot_config: %{"fallback_model" => "claude-haiku-4-5-custom"})
    entity = load_entity(bot)

    log = start_call_log([:overload, end_turn()])
    client = model_tracking_client(log, self(), nil)

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "@alice ping"},
        client_fn: client,
        model: "claude-sonnet-4-6"
      )

    assert result == {:ok, :end_turn}

    requests = collect_models(log)
    assert requests == ["claude-sonnet-4-6", "claude-haiku-4-5-custom"]
  end

  test "second 529 (fallback also overloaded) terminates cleanly" do
    bot = mint_bot([])
    entity = load_entity(bot)

    log = start_call_log([:overload, :overload])
    client = model_tracking_client(log, self(), nil)

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "@alice ping"},
        client_fn: client,
        model: "claude-sonnet-4-6",
        fallback_model: "claude-haiku-4-5-20251001"
      )

    assert {:error, {:client_failure, {:http_status, 529, _}}} = result
  end

  test "503 also triggers fallback" do
    bot = mint_bot([])
    entity = load_entity(bot)

    log =
      start_call_log([
        {:error, {:http_status, 503, %{}}},
        end_turn()
      ])

    test_pid = self()

    client = fn request ->
      send(test_pid, {:request, request.model})

      response =
        Agent.get_and_update(log, fn s ->
          [h | t] = Map.get(s, :queue, [])
          {h, Map.put(s, :queue, t)}
        end)

      case response do
        {:error, _} = err -> err
        ok_response -> {:ok, ok_response}
      end
    end

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "@alice ping"},
        client_fn: client,
        model: "claude-sonnet-4-6",
        fallback_model: "claude-haiku-4-5-20251001"
      )

    assert result == {:ok, :end_turn}
    assert collect_models(log) == ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
  end

  test "non-retryable error (400) does NOT fall back" do
    bot = mint_bot([])
    entity = load_entity(bot)

    log = self()

    client = fn request ->
      send(log, {:request, request.model})
      {:error, {:http_status, 400, %{"error" => "bad request"}}}
    end

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "@alice ping"},
        client_fn: client,
        model: "claude-sonnet-4-6",
        fallback_model: "claude-haiku-4-5-20251001"
      )

    assert {:error, {:client_failure, {:http_status, 400, _}}} = result

    # Only one request — no fallback retry on 400.
    assert_received {:request, "claude-sonnet-4-6"}
    refute_received {:request, _}
  end

  test "telemetry [:commonplace, :bots, :worker, :model_fell_back] fires" do
    bot = mint_bot([])
    entity = load_entity(bot)

    test_pid = self()

    :telemetry.attach(
      "fellback-test-#{:rand.uniform(1_000_000)}",
      [:commonplace, :bots, :worker, :model_fell_back],
      fn _e, _m, meta, _c -> send(test_pid, {:fell_back, meta}) end,
      nil
    )

    log = start_call_log([:overload, end_turn()])
    client = model_tracking_client(log, self(), nil)

    Worker.run("demo", entity, %{"message_id" => "m1", "text" => "@alice ping"},
      client_fn: client,
      model: "claude-sonnet-4-6",
      fallback_model: "claude-haiku-4-5-20251001"
    )

    assert_receive {:fell_back, %{from: "claude-sonnet-4-6", to: "claude-haiku-4-5-20251001", code: 529}},
                   500
  end

  defp collect_models(_log_pid) do
    Process.sleep(50)
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:request, model} -> receive_all([model | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
