defmodule Commonplace.Bots.TranscriptTest do
  @moduledoc """
  Camillo C5c-i (cp-plan #8895) — the turn-transcript WRITE side.

  Pins authored FROM THE SPEC (lesson #8 — never author pins by reading your
  own implementation): (a) a real `Worker.run/4` turn (look then
  post_message then end) appends EXACTLY ONE transcript entry containing the
  inbound event, the look call+truncated result, the reply text, and the
  correct wake kind — under real enforce, zone survives; (b) a turn with a
  REFUSED (not-allowlisted) tool call records the refusal as an "error"
  event; (c) an append failure (a broken transcript target) never alters the
  turn's outcome and never raises; (d) is pinned in `heartbeat_test.exs`
  (the dispatcher's heartbeat `:skip` decision never reaches `Worker.run` at
  all, so "no entry" is structural, not this module's to prove in
  isolation — see that file's PIN (d) test); (e) a multi-tool turn still
  grows the transcript by exactly ONE entry (one RMW per turn, not per
  event).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, Entity, MudContext, Transcript, Worker}
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.World
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_transcript_#{n}")
    File.mkdir_p!(dir)
    store = :"transcript_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"transcript_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"transcript_tss_#{n}",
       pending_imports_name: :"transcript_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # PIN (e)'s multi-tool turn includes a `move`, which takes green tokens
    # (World.move_presence -> Move.move -> Bursar) — a Bursar must run under
    # its default name for that path to work (mirrors mud_tools_test.exs /
    # describe_test.exs).
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        sweep_interval: 60_000
      )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_transcript_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"transcript_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      if Process.alive?(bursar_pid) do
        try do
          GenServer.stop(bursar_pid)
        catch
          :exit, _ -> :ok
        end
      end

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

    {:ok, node_ctx} = NodeIdentity.signing_context()

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

  defp resolve_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  defp mint_signed_text_doc(store, name, body, node_ctx) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)

    CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil, %{},
      signing_context: node_ctx
    )

    uuid
  end

  # A minimal charter (persona.md + trigger.regex + a bot.json granting
  # exactly `tools_list`) — the C3a default-closed allowlist. EVERY doc here
  # (including the dir schema itself) is NODE-SIGNED so this fixture also
  # mints cleanly under a test that wraps it in `with_enforce/1`.
  defp mint_bot_dir(ctx, tools_list) do
    config = Jason.encode!(%{"tools" => tools_list})

    schema =
      Schema.new_schema()
      |> Schema.add_file(
        "persona.md",
        mint_signed_text_doc(ctx.store, "persona.md", "You are camillo.", ctx.node_ctx)
      )
      |> Schema.add_file(
        "trigger.regex",
        mint_signed_text_doc(ctx.store, "trigger.regex", "(?i)@camillo\\b", ctx.node_ctx)
      )
      |> Schema.add_file(
        "bot.json",
        mint_signed_text_doc(ctx.store, "bot.json", config, ctx.node_ctx)
      )

    uuid = UUID.uuid4()

    CommitStore.create_commit(ctx.store, uuid, Encoding.encode_update(schema), nil, %{},
      signing_context: ctx.node_ctx
    )

    uuid
  end

  defp load_entity(ctx, uuid, display_name) do
    {:ok, entity} = Entity.load(ctx.store, uuid, display_name)
    entity
  end

  defp mint_messages_doc(ctx) do
    uuid = UUID.uuid4()

    CommitStore.create_commit(ctx.store, uuid, Encoding.encode_update(Messages.new()), nil, %{},
      signing_context: ctx.node_ctx
    )

    uuid
  end

  # A {:docs, [messages_uuid]} write cert for camillo's OWN identity — the
  # C4-style mechanism a non-subtree doc (a room's _messages, outside his
  # home) needs (see TelegramBridge's moduledoc for the same shape).
  defp messages_cert_cids(ctx, sc, messages_uuid) do
    {:ok, cap} =
      Capability.issue(ctx.node_ctx, {sc.identity_uuid, sc.public_key}, %{
        verbs: [:write],
        scope: {:docs, [messages_uuid]}
      })

    :ok = CommitStore.store_capability(ctx.store, cap)
    [cap.id]
  end

  defp with_enforce(fun) do
    prior_gate = Application.get_env(:commonplace, :local_write_gate)
    prior_trust = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    try do
      fun.()
    after
      case prior_gate do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      case prior_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end
    end
  end

  defp event(text) do
    %{"message_id" => "m1", "author_path" => "jes.usr", "text" => text}
  end

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
      "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
      "usage" => %{"output_tokens" => 20}
    }
  end

  ## --- PIN (a) ---

  test "PIN (a): a real Worker.run turn (look, post_message, end) appends EXACTLY ONE entry; zone survives under enforce",
       ctx do
    with_enforce(fn ->
      {prov, sc, mud_ctx} = resolve_camillo(ctx)
      messages_uuid = mint_messages_doc(ctx)
      cert_cids = messages_cert_cids(ctx, sc, messages_uuid)

      bot_dir = mint_bot_dir(ctx, ["look", "post_message"])
      entity = load_entity(ctx, bot_dir, "camillo.bot")

      responses = [
        tool_use("t1", "look", %{}),
        tool_use("t2", "post_message", %{"text" => "hello there, jes"}),
        end_turn()
      ]

      assert {:ok, :end_turn} =
               Worker.run("jes", entity, event("hi camillo"),
                 root_uuid: ctx.mud_root,
                 store: ctx.store,
                 secret_store: ctx.secrets,
                 client_fn: stub_client(responses),
                 messages_uuid: messages_uuid,
                 cert_cids: cert_cids,
                 presence_enabled: false
               )

      entries = Transcript.read(mud_ctx)
      assert length(entries) == 1

      [entry] = entries
      assert entry["wake"] == "chat"
      assert is_binary(entry["ts"])

      events = entry["events"]

      assert %{"type" => "inbound", "author" => "jes.usr", "text" => "hi camillo"} in events

      assert Enum.any?(events, fn e ->
               e["type"] == "tool_call" and e["tool"] == "look" and is_binary(e["result"])
             end)

      assert %{"type" => "reply", "text" => "hello there, jes"} in events

      # Zone survives (merge_meta, never a struct round-trip — CX-cl65).
      {:ok, transcript_uuid} = child_dir(mud_ctx.home_room_uuid, "transcript", ctx.store)
      assert transcript_uuid == prov.transcript_uuid
      {:ok, note_map} = World.get_meta_map(transcript_uuid, "__note.json", ctx.store)
      assert note_map["zone"] == prov.home_room_uuid
    end)
  end

  ## --- PIN (b) ---

  test "PIN (b): a not-allowlisted tool call records a refusal (\"error\") event", ctx do
    {_prov, sc, mud_ctx} = resolve_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    cert_cids = messages_cert_cids(ctx, sc, messages_uuid)

    # The charter grants ONLY "look" — "scratch" is NOT allowlisted.
    bot_dir = mint_bot_dir(ctx, ["look"])
    entity = load_entity(ctx, bot_dir, "camillo.bot")

    responses = [
      tool_use("t1", "scratch", %{"note" => "should be refused"}),
      end_turn()
    ]

    assert {:ok, :end_turn} =
             Worker.run("jes", entity, event("try something"),
               root_uuid: ctx.mud_root,
               store: ctx.store,
               secret_store: ctx.secrets,
               client_fn: stub_client(responses),
               messages_uuid: messages_uuid,
               cert_cids: cert_cids,
               presence_enabled: false
             )

    [entry] = Transcript.read(mud_ctx)
    events = entry["events"]

    assert Enum.any?(events, fn e ->
             e["type"] == "error" and e["tool"] == "scratch" and
               e["reason"] =~ "not allowlisted"
           end)

    # It is STILL exactly one turn entry — the refusal didn't fork the append.
    assert length(Transcript.read(mud_ctx)) == 1
  end

  ## --- PIN (c) ---

  test "PIN (c): a broken transcript target (bad home_room_uuid) never alters the outcome, never raises",
       ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)
    broken_ctx = %{mud_ctx | home_room_uuid: UUID.uuid4()}

    entity = load_entity(ctx, mint_bot_dir(ctx, ["look"]), "camillo.bot")

    base_state = %{
      room: "jes",
      entity: entity,
      event: event("hello"),
      mud_ctx: broken_ctx,
      config: %{
        max_calls: 3,
        max_output_tokens: 100,
        max_wall_ms: 5_000,
        model: "test-model",
        fallback_model: nil
      },
      client_fn: stub_client([end_turn()]),
      tools_module: Commonplace.Bots.Worker.Tools,
      signing_context: nil,
      allowlist: ["look"],
      opts: [store: ctx.store]
    }

    # Would raise/crash here if the append weren't rescue-safe. It doesn't.
    assert {:ok, :end_turn} = Commonplace.Bots.Worker.Loop.run(base_state)
  end

  ## --- PIN (e) ---

  test "PIN (e): a multi-tool turn still grows the transcript by exactly ONE entry", ctx do
    {_prov, sc, mud_ctx} = resolve_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    cert_cids = messages_cert_cids(ctx, sc, messages_uuid)

    tools = ["look", "scratch", "describe", "move", "post_message"]
    bot_dir = mint_bot_dir(ctx, tools)
    entity = load_entity(ctx, bot_dir, "camillo.bot")

    assert Transcript.read(mud_ctx) == []

    responses = [
      tool_use("t1", "look", %{}),
      tool_use("t2", "scratch", %{"note" => "a stray thought"}),
      tool_use("t3", "describe", %{"text" => "A tidy little foyer."}),
      tool_use("t4", "move", %{"direction" => "north"}),
      tool_use("t5", "post_message", %{"text" => "all done for now"}),
      end_turn()
    ]

    assert {:ok, :end_turn} =
             Worker.run("jes", entity, event("busy turn"),
               root_uuid: ctx.mud_root,
               store: ctx.store,
               secret_store: ctx.secrets,
               client_fn: stub_client(responses),
               messages_uuid: messages_uuid,
               cert_cids: cert_cids,
               presence_enabled: false
             )

    entries = Transcript.read(mud_ctx)
    assert length(entries) == 1

    [entry] = entries
    types = Enum.map(entry["events"], & &1["type"])
    # inbound + look(tool_call) + scratch(act) + describe(act) + move(move) + reply
    assert "inbound" in types
    assert "tool_call" in types
    assert "act" in types
    assert "move" in types
    assert "reply" in types
    assert length(types) == 6

    # A SECOND multi-tool turn grows the count by exactly one more, not five.
    assert {:ok, :end_turn} =
             Worker.run("jes", entity, event("another busy turn"),
               root_uuid: ctx.mud_root,
               store: ctx.store,
               secret_store: ctx.secrets,
               client_fn:
                 stub_client([
                   tool_use("u1", "look", %{}),
                   tool_use("u2", "move", %{"direction" => "south"}),
                   end_turn()
                 ]),
               messages_uuid: messages_uuid,
               cert_cids: cert_cids,
               presence_enabled: false
             )

    assert length(Transcript.read(mud_ctx)) == 2
  end

  defp child_dir(parent, name, store) do
    with {:ok, schema} <- Commonplace.MUD.Schemas.load_dir_schema(parent, store),
         {:ok, %{node_id: node_id}} <- Schema.get_entry(schema, name) do
      {:ok, node_id}
    end
  end
end
