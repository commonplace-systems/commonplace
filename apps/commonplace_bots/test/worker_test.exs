defmodule Commonplace.Bots.WorkerTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Citizen, Entity, Worker}
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.{AgentKeys, Signing}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.World
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
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

  # Camillo C3a: the tool registry is now DEFAULT-CLOSED — a bot gets only
  # the tools in its grantor-signed bot.json charter. These loop-mechanics
  # tests exercise real tools (post_message / remember / ...), so every test
  # bot is given a NODE-SIGNED bot.json granting the full tool set (the node
  # is the v1 grantor; data_dir is this test's tmp dir so NodeIdentity mints
  # a deterministic node key here). Any `:bot_config` a test passes is merged
  # in, defaulting the `"tools"` grant when the test doesn't override it.
  @all_tools ~w(post_message remember read_chat read_memory list_files read_file check_turn_remaining)

  defp mint_bot_dir(opts) do
    persona = Keyword.get(opts, :persona, "You are alice.")
    trigger = Keyword.get(opts, :trigger, "(?i)@alice\\b")

    config =
      (Keyword.get(opts, :bot_config) || %{})
      |> Map.put_new("tools", @all_tools)

    Schema.new_schema()
    |> Schema.add_file("persona.md", mint_text_doc("persona.md", persona))
    |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
    |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", trigger))
    |> Schema.add_file("bot.json", mint_signed_text_doc("bot.json", Jason.encode!(config)))
    |> mint_doc()
  end

  # A text doc whose commit is NODE-signed — the C3a charter grantor.
  defp mint_signed_text_doc(name, body) do
    {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)

    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil, %{},
      signing_context: node_ctx
    )

    uuid
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  # Camillo C1: seed a workspace root + an isolated SecretStore so a worker
  # can resolve a REAL per-bot signing context. Returns `{root, secrets}`.
  # The registrar defaults to the (absent) node context → unsigned
  # registration on this permissive test node, which is fine — the bot's
  # own key is still minted and used to sign its writes.
  defp signing_fixture do
    root = mint_doc(Schema.new_schema())

    secrets_dir =
      Path.join(System.tmp_dir!(), "cp_bots_worker_secrets_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(secrets_dir)
    secrets = :"cp_bots_worker_secrets_#{:rand.uniform(1_000_000_000)}"
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

    {root, secrets}
  end

  defp resolved_signer_id(name, root, secrets) do
    {:ok, identity_uuid} = Identity.lookup(name, :bot, root, CommitStoreClient)
    {:ok, pub} = AgentKeys.ensure(identity_uuid, secrets)
    Signing.signer_id(identity_uuid, pub)
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
        Worker.run("demo", entity, event("@alice ping"), client_fn: stub_client([end_turn("hi")]))

      assert result == {:ok, :end_turn}
    end

    test "dispatches a single tool_use, then ends — post is SIGNED by the bot's own key" do
      {root, secrets} = signing_fixture()
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
          messages_uuid: messages_uuid,
          root_uuid: root,
          secret_store: secrets
        )

      assert result == {:ok, :end_turn}

      {:ok, msgs_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid)
      [entry] = Messages.list(msgs_doc)
      assert entry["text"] == "hello from alice"
      assert entry["author_path"] == "alice.bot"

      # Camillo C1: the worker resolved a REAL per-bot signing context and
      # the post is signed by alice's own key — not the retired "bot:alice"
      # placeholder.
      expected_signer = resolved_signer_id("alice", root, secrets)
      assert entry["author_signer_id"] == expected_signer
      refute String.starts_with?(entry["author_signer_id"], "bot:")

      {:ok, head} = CommitStore.latest_commit(Commonplace.Store.CommitStore, messages_uuid)
      assert Signing.signed?(head)
      assert head.signer_id == expected_signer
    end

    test "remember tool signs the memory append with the bot's own key" do
      # C3d: memory lands UNDER the bot's home (home/memory note-meta), so the
      # bot must be a provisioned citizen for `remember` to resolve a mud_ctx.
      {root, secrets} = signing_fixture()
      {:ok, prov} = Citizen.provision("alice", root, CommitStoreClient, secret_store: secrets)
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")

      responses = [
        tool_use("t1", "remember", %{"text" => "the human likes tea"}),
        end_turn()
      ]

      result =
        Worker.run("demo", entity, event("@alice remember"),
          client_fn: stub_client(responses),
          root_uuid: root,
          secret_store: secrets
        )

      assert result == {:ok, :end_turn}

      Commonplace.Tree.DocCache.clear()
      {:ok, note_map} = World.get_meta_map(prov.memory_uuid, "__note.json", CommitStoreClient)
      assert [%{"text" => "the human likes tea"}] = note_map["entries"]

      # The memory-append commit carries the bot's signing context.
      {:ok, meta_uuid} = World.meta_doc_uuid(prov.memory_uuid, "__note.json", CommitStoreClient)
      {:ok, head} = CommitStore.latest_commit(Commonplace.Store.CommitStore, meta_uuid)
      assert Signing.signed?(head)
      assert head.signer_id == resolved_signer_id("alice", root, secrets)
    end

    test "runtime path IGNORES a registrar_signing_context planted in worker opts (security)" do
      {root, secrets} = signing_fixture()
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")
      messages_uuid = mint_messages_doc()

      # An attacker-shaped opt: a foreign registrar the caller does NOT
      # control the trust of. The Worker runtime path must NOT forward it
      # to Identity.resolve_signing_context — the registration is
      # node-attested (defaulted), never attested by this planted key.
      {pub, priv} = Signing.generate_keypair()

      planted = %Commonplace.Crypto.SigningContext{
        identity_uuid: "attacker-registrar",
        private_key: priv,
        public_key: pub
      }

      result =
        Worker.run("demo", entity, event("@alice hi"),
          client_fn: stub_client([tool_use("t1", "post_message", %{"text" => "hi"}), end_turn()]),
          messages_uuid: messages_uuid,
          root_uuid: root,
          secret_store: secrets,
          registrar_signing_context: planted
        )

      assert result == {:ok, :end_turn}

      # The identity-doc registration commit was NOT signed by the planted
      # registrar (the runtime path dropped it). On this permissive test
      # node there is no node key, so it is simply unsigned — but crucially
      # never carries the attacker's signer.
      {:ok, identity_uuid} = Identity.lookup("alice", :bot, root, CommitStoreClient)
      {:ok, id_head} = CommitStore.latest_commit(Commonplace.Store.CommitStore, identity_uuid)
      refute id_head.signer_id == Signing.signer_id(planted.identity_uuid, planted.public_key)
    end

    test "remember tool appends an entry to home/memory" do
      # C3a: the charter gate keys the allowlist on the bot's resolved
      # identity, so a real signing fixture (root + secrets) is needed for
      # the node-signed tools grant to take effect. C3d: memory is home-anchored.
      {root, secrets} = signing_fixture()
      {:ok, prov} = Citizen.provision("alice", root, CommitStoreClient, secret_store: secrets)
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
          messages_uuid: messages_uuid,
          root_uuid: root,
          secret_store: secrets
        )

      assert result == {:ok, :end_turn}

      Commonplace.Tree.DocCache.clear()
      {:ok, note_map} = World.get_meta_map(prov.memory_uuid, "__note.json", CommitStoreClient)
      assert [entry] = note_map["entries"]
      assert entry["text"] == "the human likes coffee"
      assert entry["source_msg_id"] == "m1"
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
               Worker.run("demo", entity, event("@alice"), client_fn: stub_client(responses))
    end

    test "client failure terminates with :error" do
      bot = mint_bot_dir([])
      entity = load_entity(bot, "alice.bot")

      result =
        Worker.run("demo", entity, event("@alice"), client_fn: fn _ -> {:error, :boom} end)

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

    # C5a pin (c): budget override is per-bot-only. A bot whose bot.json
    # carries `max_wall_ms` gets THAT ceiling; a bot with no override falls
    # back to the module default (`@default_max_wall_ms`, 60_000ms) — same
    # `fetch_pos_int/5` path max_calls/max_output_tokens already use.
    test "bot.json max_wall_ms overrides default for THAT bot only; an unset bot keeps the default" do
      overridden_bot = mint_bot_dir(bot_config: %{"max_wall_ms" => 5})
      plain_bot = mint_bot_dir([])

      overridden_entity = load_entity(overridden_bot, "alice.bot")
      plain_entity = load_entity(plain_bot, "alice.bot")
      messages_uuid = mint_messages_doc()

      # A single tool_use response, but the client SLEEPS 20ms before
      # returning it — long enough that the loop's SECOND wall-clock check
      # (before the would-be next POST) reads elapsed >= 5ms for the
      # overridden bot, but nowhere near the 60_000ms default for the plain
      # bot. Only one queued response is needed either way: the overridden
      # bot never gets to issue a second POST (caps first), and the plain
      # bot's second iteration would also be a real POST — so give it an
      # end_turn as its "second" response too, reachable only if it did NOT
      # cap.
      slow_client = fn _request ->
        Process.sleep(20)
        {:ok, tool_use("t1", "post_message", %{"text" => "first"})}
      end

      overridden_result =
        Worker.run("demo", overridden_entity, event("@alice"),
          client_fn: slow_client,
          messages_uuid: messages_uuid
        )

      # With a 5ms ceiling and a 20ms-per-call client, the SECOND
      # iteration's wall-clock check reads elapsed >= 5ms and caps out
      # BEFORE issuing a second POST.
      assert overridden_result == {:cap_hit, :wall_clock}

      plain_result =
        Worker.run("demo", plain_entity, event("@alice"),
          client_fn:
            stub_client([
              tool_use("t1", "post_message", %{"text" => "first"}),
              end_turn()
            ]),
          messages_uuid: messages_uuid
        )

      # No sleep in this one at all — proves the DEFAULT ceiling (60_000ms)
      # applies to a bot with no override, letting it run to completion.
      assert plain_result == {:ok, :end_turn}
    end
  end
end
