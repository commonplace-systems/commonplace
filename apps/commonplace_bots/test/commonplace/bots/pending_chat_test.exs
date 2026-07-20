defmodule Commonplace.Bots.PendingChatTest do
  @moduledoc """
  Camillo batch part 4 (cp-plan, the jes gap) — REAL thread-idle +
  pending-chat surfacing, replacing the `"thread_quiet" => true` stub.

  Pins authored FROM THE SPEC (lesson #8): (i) a pending (non-bot,
  newest) chat message wakes a heartbeat tick even with an EMPTY agenda
  — §10's wake-source #1 ("a person is waiting") finally reaching the
  skip-check, RED against the stub (verified below, restored after);
  (ii) the assembled wake text carries the pending block in STIMULUS
  POSITION (before "You woke on a heartbeat"), with its age; (iii)
  bot-authored-newest stays quiet — empty agenda + an already-answered
  thread still skips (the cheap-tick property intact); (iv) end-to-end:
  a REAL `Worker.run/4` heartbeat wake carrying a pending message lets
  him `post_message` and the reply genuinely lands in the room.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, Dispatcher, Entity, MudContext, Worker}
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_pending_#{n}")
    File.mkdir_p!(dir)
    store = :"pending_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"pending_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"pending_tss_#{n}",
       pending_imports_name: :"pending_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_pending_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"pending_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    test_pid = self()
    hook = fn room, entity, event -> send(test_pid, {:wake, room, entity.name, event}) end

    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Dispatcher,
           [worker_hook: hook, rate_limit_enabled: false, store: store, node_ctx: node_ctx]},
          id: Dispatcher
        )
      )

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Dispatcher)
      Process.sleep(100)

      {:ok, _pid} =
        Supervisor.start_child(bots_sup, Supervisor.child_spec({Dispatcher, []}, id: Dispatcher))

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

  ## --- Fixtures ---

  defp mint_text_doc(store, name, body, node_ctx) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)

    CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil, %{},
      signing_context: node_ctx
    )

    uuid
  end

  defp mint_bot_dir(ctx, tools_list) do
    config = Jason.encode!(%{"tools" => tools_list})

    schema =
      Schema.new_schema()
      |> Schema.add_file(
        "persona.md",
        mint_text_doc(ctx.store, "persona.md", "You are camillo.", ctx.node_ctx)
      )
      |> Schema.add_file(
        "trigger.regex",
        mint_text_doc(ctx.store, "trigger.regex", "(?i)@camillo\\b", ctx.node_ctx)
      )
      |> Schema.add_file("bot.json", mint_text_doc(ctx.store, "bot.json", config, ctx.node_ctx))

    uuid = UUID.uuid4()

    CommitStore.create_commit(ctx.store, uuid, Encoding.encode_update(schema), nil, %{},
      signing_context: ctx.node_ctx
    )

    uuid
  end

  defp provision_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  defp mint_messages_doc(ctx) do
    uuid = UUID.uuid4()

    CommitStore.create_commit(ctx.store, uuid, Encoding.encode_update(Messages.new()), nil, %{},
      signing_context: ctx.node_ctx
    )

    uuid
  end

  defp mint_room_dir(ctx) do
    uuid = UUID.uuid4()

    CommitStore.create_commit(
      ctx.store,
      uuid,
      Encoding.encode_update(Schema.new_schema()),
      nil,
      %{},
      signing_context: ctx.node_ctx
    )

    uuid
  end

  defp messages_cert_cids(ctx, sc, messages_uuid) do
    {:ok, cap} =
      Capability.issue(ctx.node_ctx, {sc.identity_uuid, sc.public_key}, %{
        verbs: [:write],
        scope: {:docs, [messages_uuid]}
      })

    :ok = CommitStore.store_capability(ctx.store, cap)
    [cap.id]
  end

  defp tick(name), do: send(Process.whereis(Dispatcher), {:autonomous_tick, name})

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
      "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
      "usage" => %{"output_tokens" => 20}
    }
  end

  defp capturing_stub_client(test_pid, responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      send(test_pid, {:request, request})

      case Agent.get_and_update(agent, fn
             [] -> {[], []}
             [h | t] -> {h, t}
           end) do
        [] -> {:error, :stub_exhausted}
        response -> {:ok, response}
      end
    end
  end

  defp first_wake_text(request) do
    request
    |> Map.get(:messages)
    |> List.first()
    |> Map.get("content")
    |> List.first()
    |> Map.get("text")
  end

  ## ---- PIN (i) + (ii): pending message wakes an empty-agenda tick; wake
  ## text carries it in stimulus position, with age ----

  test "PIN (i)+(ii): a pending human message wakes an EMPTY-agenda tick; the wake text names it before the agenda, with age",
       ctx do
    {_prov, sc, _mud_ctx} = provision_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    room_dir = mint_room_dir(ctx)

    :ok = Dispatcher.subscribe_room("jes", room_dir, messages_uuid)

    {:ok, _} =
      Actions.post_message(messages_uuid, "hey camillo, you there?",
        room: "jes",
        signer_id: "jes-human-signer",
        author_path: "jes.usr",
        store: ctx.store
      )

    bot_dir = mint_bot_dir(ctx, ["post_message"])

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets,
        chat_rooms: ["jes"]
      )

    tick("camillo")

    assert_receive {:wake, "camillo", "camillo", event}, 2_000

    # THE PIN (i): woke despite an EMPTY agenda.
    assert event["agenda_empty"] == true
    assert event["thread_quiet"] == false
    assert event["pending"]["text"] == "hey camillo, you there?"
    assert event["pending"]["author"] == "jes.usr"
    assert is_binary(event["pending"]["ts"])

    # THE PIN (ii): drive the SAME event through a real turn to inspect the
    # assembled wake text.
    entity = load_entity(ctx, bot_dir, "camillo.bot")
    test_pid = self()

    assert {:ok, :end_turn} =
             Worker.run("camillo", entity, event,
               root_uuid: ctx.mud_root,
               store: ctx.store,
               secret_store: ctx.secrets,
               client_fn: capturing_stub_client(test_pid, [end_turn()]),
               presence_enabled: false
             )

    assert_receive {:request, request}
    text = first_wake_text(request)

    assert text =~ ~s(jes.usr said: "hey camillo, you there?")
    assert text =~ ~r/\(about \d+ minutes? ago\)/
    assert text =~ "you have not yet answered"
    assert text =~ "A person is waiting"

    pending_idx = idx(text, "you have not yet answered")
    woke_idx = idx(text, "You woke on a heartbeat")
    assert pending_idx < woke_idx

    _ = sc
  end

  ## ---- PIN (iii): bot-authored-newest stays quiet — skip preserved ----

  test "PIN (iii): bot-authored newest message + empty agenda stays QUIET — skip preserved",
       ctx do
    {_prov, sc, _mud_ctx} = provision_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    room_dir = mint_room_dir(ctx)

    :ok = Dispatcher.subscribe_room("jes", room_dir, messages_uuid)

    bot_signer_id = Commonplace.Crypto.Signing.signer_id(sc.identity_uuid, sc.public_key)

    {:ok, _} =
      Actions.post_message(messages_uuid, "already answered",
        room: "jes",
        signer_id: bot_signer_id,
        author_path: "camillo.bot",
        store: ctx.store
      )

    bot_dir = mint_bot_dir(ctx, ["post_message"])

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets,
        chat_rooms: ["jes"]
      )

    tick("camillo")

    # Empty agenda + the thread's newest entry already his own -> quiet -> skip.
    refute_receive {:wake, _, _, _}, 400
  end

  ## ---- PIN (iv): end-to-end — a real heartbeat wake carrying a pending
  ## message, he posts, and the reply lands ----

  test "PIN (iv): end-to-end — a real Worker.run heartbeat wake with a pending message; his reply lands",
       ctx do
    {_prov, sc, _mud_ctx} = provision_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    room_dir = mint_room_dir(ctx)
    cert_cids = messages_cert_cids(ctx, sc, messages_uuid)

    :ok = Dispatcher.subscribe_room("jes", room_dir, messages_uuid)

    {:ok, _} =
      Actions.post_message(messages_uuid, "still there?",
        room: "jes",
        signer_id: "jes-human-signer",
        author_path: "jes.usr",
        store: ctx.store
      )

    bot_dir = mint_bot_dir(ctx, ["post_message"])
    entity = load_entity(ctx, bot_dir, "camillo.bot")

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets,
        chat_rooms: ["jes"]
      )

    tick("camillo")
    assert_receive {:wake, "camillo", "camillo", event}, 2_000
    assert event["thread_quiet"] == false

    responses = [
      tool_use("t1", "post_message", %{"text" => "Still here, jes!"}),
      end_turn()
    ]

    assert {:ok, :end_turn} =
             Worker.run("camillo", entity, event,
               root_uuid: ctx.mud_root,
               store: ctx.store,
               secret_store: ctx.secrets,
               client_fn: capturing_stub_client(self(), responses),
               messages_uuid: messages_uuid,
               cert_cids: cert_cids,
               presence_enabled: false
             )

    {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, messages_uuid)
    entries = Messages.materialize(doc)

    assert Enum.any?(entries, &(&1["text"] == "Still here, jes!"))
  end

  defp idx(text, substr) do
    case :binary.match(text, substr) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  defp load_entity(ctx, uuid, display_name) do
    {:ok, entity} = Entity.load(ctx.store, uuid, display_name)
    entity
  end
end
