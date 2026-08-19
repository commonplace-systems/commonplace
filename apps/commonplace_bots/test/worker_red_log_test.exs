defmodule Commonplace.Bots.Worker.RedLogTest do
  @moduledoc """
  CX-q8nk(2): per-entity __red_log — workers append their outcome
  events to the bot's own red log when one exists. Distinct from
  the room-level __bot_activity log (CX-gptu).

  A bot operating across multiple rooms gets one durable trail
  here keyed by bot, not by room.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Entity, Worker}
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_redlog_#{:rand.uniform(1_000_000_000)}")
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

  defp mint_red_log_doc do
    uuid = UUID.uuid4()
    log = RedLog.new(uuid)
    update = Yelixer.Encoding.encode_update(log.doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_bot_dir(opts) do
    include_red_log = Keyword.get(opts, :with_red_log, true)

    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "alice"))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", "(?i)@alice"))

    schema =
      if include_red_log do
        Schema.add_file(schema, "__red_log", mint_red_log_doc())
      else
        schema
      end

    mint_doc(schema)
  end

  defp load_entity(uuid), do: elem(Entity.load(CommitStoreClient, uuid, "alice.bot"), 1)

  defp red_log_entries(red_log_uuid) do
    Commonplace.Tree.DocCache.clear()
    log = RedLog.load(red_log_uuid)
    RedLog.read(log)
  end

  defp end_turn do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "ok"}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  defp signing_fixture do
    root = mint_doc(Schema.new_schema())

    secrets_dir =
      Path.join(System.tmp_dir!(), "cp_bots_redlog_keys_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(secrets_dir)
    secrets = :"cp_bots_redlog_keys_#{:rand.uniform(1_000_000_000)}"
    _secrets_pid = start_supervised!({SecretStore, data_dir: secrets_dir, name: secrets})
    on_exit(fn -> File.rm_rf!(secrets_dir) end)

    {pub, priv} = Signing.generate_keypair()

    registrar = %SigningContext{
      identity_uuid: UUID.uuid4(),
      private_key: priv,
      public_key: pub
    }

    {:ok, signing_context} =
      Commonplace.Bots.Identity.resolve_signing_context("alice", root, CommitStoreClient,
        secret_store: secrets,
        registrar_signing_context: registrar
      )

    {root, secrets, signing_context}
  end

  defp strict_on_worker_start(signing_contexts) do
    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)
    test_pid = self()
    id = "worker-red-log-enforce-#{System.unique_integer([:positive])}"

    trusted =
      Map.new(signing_contexts, fn ctx ->
        {ctx.identity_uuid, Signing.encode_key(ctx.public_key)}
      end)

    :ok =
      :telemetry.attach(
        id,
        [:commonplace, :bots, :worker, :started],
        fn _event, _measurements, _metadata, _ ->
          Application.put_env(:commonplace, :trust, %{
            accept_unsigned: false,
            trusted_identities: trusted
          })

          Application.put_env(:commonplace, :local_write_gate, :enforce)
          send(test_pid, :worker_gate_enabled)
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(id)

      if is_nil(old_trust),
        do: Application.delete_env(:commonplace, :trust),
        else: Application.put_env(:commonplace, :trust, old_trust)

      if is_nil(old_gate),
        do: Application.delete_env(:commonplace, :local_write_gate),
        else: Application.put_env(:commonplace, :local_write_gate, old_gate)
    end)
  end

  defp attach_red_log_telemetry do
    test_pid = self()
    id = "worker-red-log-result-#{System.unique_integer([:positive])}"

    for event <- [
          [:commonplace, :bots, :worker, :red_log_written],
          [:commonplace, :bots, :worker, :red_log_write_failed]
        ] do
      :ok =
        :telemetry.attach(
          "#{id}-#{List.last(event)}",
          event,
          fn name, measurements, metadata, _ ->
            send(test_pid, {:red_log_telemetry, name, measurements, metadata})
          end,
          nil
        )
    end

    on_exit(fn ->
      :telemetry.detach("#{id}-red_log_written")
      :telemetry.detach("#{id}-red_log_write_failed")
    end)
  end

  test "end_turn appends a 'completed' entry" do
    bot = mint_bot_dir([])
    entity = load_entity(bot)

    {:ok, :end_turn} =
      Worker.run(
        "demo",
        entity,
        %{"message_id" => "m1", "author_path" => "human.usr", "text" => "hi"},
        client_fn: fn _ -> {:ok, end_turn()} end,
        presence_enabled: false
      )

    entries = red_log_entries(entity.children["__red_log"])
    assert length(entries) == 1
    [entry] = entries
    assert entry["decision"] == "completed"
    assert entry["kind"] == "worker_outcome"
    assert entry["room"] == "demo"
    assert entry["bot"] == "alice"
    assert entry["message_id"] == "m1"
    assert entry["source_author"] == "human.usr"
    assert is_binary(entry["ts"])
  end

  test "worker outcome log lands with the resolved bot fixture identity under enforce" do
    {root, secrets, signing_context} = signing_fixture()
    bot = mint_bot_dir([])
    entity = load_entity(bot)
    strict_on_worker_start([signing_context])

    assert {:ok, :end_turn} =
             Worker.run(
               "demo",
               entity,
               %{"message_id" => "m-enforce", "author_path" => "human.usr", "text" => "hi"},
               client_fn: fn _ -> {:ok, end_turn()} end,
               presence_enabled: false,
               root_uuid: root,
               secret_store: secrets
             )

    assert_receive :worker_gate_enabled
    assert [%{"message_id" => "m-enforce"}] = red_log_entries(entity.children["__red_log"])
    {:ok, head} = CommitStore.latest_commit(CommitStore, entity.children["__red_log"])

    assert head.signer_id ==
             Signing.signer_id(signing_context.identity_uuid, signing_context.public_key)
  end

  test "worker surfaces a refused outcome-log write instead of reporting success" do
    {root, secrets, _signing_context} = signing_fixture()
    bot = mint_bot_dir([])
    entity = load_entity(bot)
    strict_on_worker_start([])
    attach_red_log_telemetry()

    assert {:ok, :end_turn} =
             Worker.run(
               "demo",
               entity,
               %{"message_id" => "m-refused", "author_path" => "human.usr", "text" => "hi"},
               client_fn: fn _ -> {:ok, end_turn()} end,
               presence_enabled: false,
               root_uuid: root,
               secret_store: secrets
             )

    assert_receive :worker_gate_enabled

    assert_receive {:red_log_telemetry, [:commonplace, :bots, :worker, :red_log_write_failed], _,
                    metadata}

    assert metadata.reason =~ "trust_rejected"
    refute_receive {:red_log_telemetry, [:commonplace, :bots, :worker, :red_log_written], _, _}
  end

  test "cap_hit outcome appends with reason" do
    bot = mint_bot_dir([])
    entity = load_entity(bot)

    tool_use = %{
      "stop_reason" => "tool_use",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "t1",
          "name" => "post_message",
          "input" => %{"text" => "x"}
        }
      ],
      "usage" => %{"output_tokens" => 10}
    }

    messages_uuid = UUID.uuid4()

    CommitStore.create_commit(
      Commonplace.Store.CommitStore,
      messages_uuid,
      Yelixer.Encoding.encode_update(Commonplace.Chat.Messages.new()),
      nil
    )

    result =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "spam"},
        client_fn: fn _ -> {:ok, tool_use} end,
        messages_uuid: messages_uuid,
        max_calls: 1,
        presence_enabled: false
      )

    assert result == {:cap_hit, :calls}

    [entry] = red_log_entries(entity.children["__red_log"])
    assert entry["decision"] == "cap_hit"
    assert entry["reason"] == "calls"
  end

  test "error outcome appends with reason" do
    bot = mint_bot_dir([])
    entity = load_entity(bot)

    {:error, _} =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "boom"},
        client_fn: fn _ -> {:error, :boom} end,
        presence_enabled: false
      )

    [entry] = red_log_entries(entity.children["__red_log"])
    assert entry["decision"] == "error"
    assert entry["reason"] =~ "boom"
  end

  test "multiple turns accumulate entries oldest-first" do
    bot = mint_bot_dir([])
    entity = load_entity(bot)

    for i <- 1..3 do
      Worker.run("demo", entity, %{"message_id" => "m#{i}", "text" => "hi"},
        client_fn: fn _ -> {:ok, end_turn()} end,
        presence_enabled: false
      )
    end

    entries = red_log_entries(entity.children["__red_log"])
    assert length(entries) == 3
    assert Enum.map(entries, & &1["message_id"]) == ["m1", "m2", "m3"]
  end

  test "cross-room appends share one log" do
    bot = mint_bot_dir([])
    entity = load_entity(bot)

    Worker.run("room-a", entity, %{"message_id" => "m1", "text" => "hi"},
      client_fn: fn _ -> {:ok, end_turn()} end,
      presence_enabled: false
    )

    Worker.run("room-b", entity, %{"message_id" => "m2", "text" => "hi"},
      client_fn: fn _ -> {:ok, end_turn()} end,
      presence_enabled: false
    )

    entries = red_log_entries(entity.children["__red_log"])
    rooms = entries |> Enum.map(& &1["room"]) |> Enum.sort()
    assert rooms == ["room-a", "room-b"]
  end

  test "no __red_log child → silent no-op (no crash)" do
    bot = mint_bot_dir(with_red_log: false)
    entity = load_entity(bot)
    refute Map.has_key?(entity.children, "__red_log")

    # Should still succeed end-to-end.
    {:ok, :end_turn} =
      Worker.run("demo", entity, %{"message_id" => "m1", "text" => "hi"},
        client_fn: fn _ -> {:ok, end_turn()} end,
        presence_enabled: false
      )
  end

  test "Demo.bootstrap mints __red_log on each bot by default" do
    root_uuid = UUID.uuid4()
    root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, root_update, nil)

    demo = Commonplace.Bots.Demo.bootstrap(root_uuid)

    for {name, dir_uuid} <- demo.bots do
      {:ok, entity} = Entity.load(CommitStoreClient, dir_uuid, "#{name}.bot")

      assert is_binary(entity.children["__red_log"]),
             "expected __red_log child on bot #{name}, got: #{inspect(entity.children)}"
    end
  end
end
