defmodule Commonplace.Bots.ScrollbackTest do
  @moduledoc """
  Camillo C5c-ii (cp-plan #8895) — the scrollback WAKE INJECTION, the read
  side of C5c-i's `Commonplace.Bots.Transcript`.

  Pins authored FROM THE SPEC (lesson #8): (a) the REMEMBERS pin — turn 2's
  wake text contains BOTH the prior inbound and the prior reply, in order
  perception -> scrollback -> stimulus -> invitation; (b) the budget pin —
  40+ turns still fits the ~30-event / ~2000-token window, newest retained,
  oldest-first within the window, an honest truncation line; (c) the
  degrade pin — no mud_ctx renders "You recall nothing.", never fabricated
  content; (d) the STIMULUS-DEDUPE pin, per cp-plan gate note #8901 — this
  is spec-authored FIRST, before the implementation, and is deliberately
  sharp about TWO boundary cases the dedupe comparison must get right:

    1. A genuine RE-SEND of identical text (jes texts "hi" twice) is NOT a
       duplicate — it is a second, independent stimulus with a DIFFERENT
       `message_id`. The dedupe must NEVER swallow it: the first "hi" (and
       its reply) must still be visible in the scrollback rendering of the
       turn that recorded it.
    2. A literal REPLAY of the identical wake event (same `message_id`
       appearing again) IS the one case the dedupe exists for: the
       transcript's already-recorded copy of that exact inbound event must
       not be rendered a second time in scrollback (the fresh-stimulus line
       elsewhere already covers it once) — while the REST of that turn (its
       reply, its acts) still renders normally.

  The two cases can only be told apart by IDENTITY (`message_id`), never by
  text equality — a comparison keyed on text alone cannot distinguish them,
  since case 1 and case 2 can carry byte-identical text. `Scrollback`'s
  dedupe therefore compares `state.event["message_id"]` against ONLY the
  single most-recently-recorded inbound event in the read window (never an
  older turn, never by text) — see that module's moduledoc "Stimulus
  dedupe" for the full derivation; (e) heartbeat wakes get scrollback too —
  a heartbeat turn immediately after a chat turn carries the prior reply in
  its wake text.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, Entity, MudContext, Transcript, Worker}
  alias Commonplace.Bots.Worker.Scrollback
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_scrollback_#{n}")
    File.mkdir_p!(dir)
    store = :"scrollback_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"scrollback_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"scrollback_tss_#{n}",
       pending_imports_name: :"scrollback_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_scrollback_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"scrollback_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
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

  ## --- Fixtures (mirrors transcript_test.exs) ---

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

  defp messages_cert_cids(ctx, sc, messages_uuid) do
    {:ok, cap} =
      Capability.issue(ctx.node_ctx, {sc.identity_uuid, sc.public_key}, %{
        verbs: [:write],
        scope: {:docs, [messages_uuid]}
      })

    :ok = CommitStore.store_capability(ctx.store, cap)
    [cap.id]
  end

  defp event(text, message_id \\ "m1") do
    %{"message_id" => message_id, "author_path" => "jes.usr", "text" => text}
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

  # A stub client that ALSO forwards every request it's given to the test
  # process (so a test can assert on the assembled wake text) before
  # popping the next canned response off the queue. Used ONLY for the turn
  # whose wake text a test actually wants to inspect — earlier turns use
  # the plain `stub_client/1` so they never touch the test process mailbox.
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

  defp first_wake_text(request) do
    request
    |> Map.get(:messages)
    |> List.first()
    |> Map.get("content")
    |> List.first()
    |> Map.get("text")
  end

  defp index_of(text, substr) do
    case :binary.match(text, substr) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  # A synthetic Loop-state map — the same minimal shape
  # `Commonplace.Bots.Worker.Loop.run/1` consumes, for tests that want to
  # call `Scrollback.render/1` directly without paying for a full
  # client-stubbed Worker.run round trip.
  defp loop_state(entity, mud_ctx, event) do
    %{
      room: "jes",
      entity: entity,
      event: event,
      mud_ctx: mud_ctx
    }
  end

  ## --- PIN (a): the REMEMBERS pin ---

  test "PIN (a): turn 2's wake text remembers turn 1's inbound AND reply, ordered perception -> scrollback -> stimulus -> invitation",
       ctx do
    {_prov, sc, _mud_ctx} = resolve_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    cert_cids = messages_cert_cids(ctx, sc, messages_uuid)

    bot_dir = mint_bot_dir(ctx, ["look", "post_message"])
    entity = load_entity(ctx, bot_dir, "camillo.bot")

    test_pid = self()

    common_opts = [
      root_uuid: ctx.mud_root,
      store: ctx.store,
      secret_store: ctx.secrets,
      messages_uuid: messages_uuid,
      cert_cids: cert_cids,
      presence_enabled: false
    ]

    # Turn 1: inbound "A" -> reply "X". Plain (non-capturing) client — this
    # turn's own wake text isn't what's under test.
    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("A", "m-a"),
               [
                 client_fn:
                   stub_client([
                     tool_use("t1", "post_message", %{"text" => "X"}),
                     end_turn()
                   ])
               ] ++ common_opts
             )

    # Turn 2: a DIFFERENT inbound "B" — turn 2's wake text is what we assert on.
    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("B", "m-b"),
               [client_fn: capturing_stub_client(test_pid, [end_turn()])] ++ common_opts
             )

    assert_received {:request, turn2_request}

    text = first_wake_text(turn2_request)

    assert text =~ ~s(jes.usr said: "A")
    assert text =~ ~s(You replied: "X")
    assert text =~ ~s(jes.usr says: "B")

    perception_idx = index_of(text, "You stand in") || index_of(text, "cannot feel your body")
    scrollback_said_idx = index_of(text, ~s(jes.usr said: "A"))
    scrollback_reply_idx = index_of(text, ~s(You replied: "X"))
    stimulus_idx = index_of(text, ~s(jes.usr says: "B"))
    invitation_idx = index_of(text, "You may take your time")

    assert perception_idx < scrollback_said_idx
    assert scrollback_said_idx < scrollback_reply_idx
    assert scrollback_reply_idx < stimulus_idx
    assert stimulus_idx < invitation_idx
  end

  ## --- PIN (b): the budget pin ---

  test "PIN (b): 40+ turns still fit the window — newest retained, oldest-first, truncation line present",
       ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["look"]), "camillo.bot")

    for i <- 1..40 do
      turn = %{"wake" => "chat", "events" => [%{"type" => "act", "text" => "turn #{i} act"}]}
      :ok = Transcript.append_turn(turn, mud_ctx)
    end

    state = loop_state(entity, mud_ctx, event("irrelevant stimulus", "m-irrelevant"))
    text = Scrollback.render(state)

    assert text =~ "earlier turns have faded from the moment"

    # Newest turns retained (each turn contributes exactly 1 event, so the
    # ~30-event cap keeps exactly the newest 30: turns 11..40).
    assert text =~ "Turn 40 act"
    assert text =~ "Turn 11 act"

    # Oldest dropped.
    refute text =~ "Turn 10 act"
    refute text =~ "Turn 1 act"

    # Oldest-first ORDER within the surviving window.
    idx_11 = index_of(text, "Turn 11 act")
    idx_40 = index_of(text, "Turn 40 act")
    assert idx_11 < idx_40
  end

  ## --- PIN (c): the degrade pin ---

  test "PIN (c): no mud_ctx renders \"You recall nothing.\" — never fabricated content", ctx do
    entity = load_entity(ctx, mint_bot_dir(ctx, ["look"]), "camillo.bot")
    state = loop_state(entity, nil, event("hi"))

    assert Scrollback.render(state) == "You recall nothing."
  end

  ## --- PIN (d): the stimulus-dedupe pin (spec-authored FIRST, per gate #8901) ---

  test "PIN (d) case 1: a genuine re-send (same text, DIFFERENT message_id) is NEVER deduped",
       ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["look"]), "camillo.bot")

    turn1 = %{
      "wake" => "chat",
      "events" => [
        %{"type" => "inbound", "author" => "jes.usr", "text" => "hi", "message_id" => "m-first"},
        %{"type" => "reply", "text" => "ok once"}
      ]
    }

    :ok = Transcript.append_turn(turn1, mud_ctx)

    # The SECOND "hi" is a genuinely new stimulus — different message_id.
    state2 = loop_state(entity, mud_ctx, event("hi", "m-second"))
    text = Scrollback.render(state2)

    # turn 1's recorded inbound is NOT suppressed — it's a real, distinct,
    # already-happened turn, not a duplicate of the current stimulus.
    assert text =~ ~s(jes.usr said: "hi")
    assert text =~ ~s(You replied: "ok once")
  end

  test "PIN (d) case 2: a literal message_id REPLAY drops only the duplicate inbound line, not the rest of the turn",
       ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["look"]), "camillo.bot")

    turn1 = %{
      "wake" => "chat",
      "events" => [
        %{
          "type" => "inbound",
          "author" => "jes.usr",
          "text" => "hello",
          "message_id" => "m-dup"
        },
        %{"type" => "reply", "text" => "got it"}
      ]
    }

    :ok = Transcript.append_turn(turn1, mud_ctx)

    # THE SAME message_id shows up again as the current wake's stimulus —
    # the one case dedupe exists for.
    state2 = loop_state(entity, mud_ctx, event("hello", "m-dup"))
    text = Scrollback.render(state2)

    refute text =~ ~s(jes.usr said: "hello")
    assert text =~ ~s(You replied: "got it")
  end

  test "PIN (d): a missing message_id on either side never dedupes (fail toward showing more)",
       ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)
    entity = load_entity(ctx, mint_bot_dir(ctx, ["look"]), "camillo.bot")

    # An inbound event with no message_id at all (a legacy/degenerate entry).
    turn1 = %{
      "wake" => "chat",
      "events" => [
        %{"type" => "inbound", "author" => "jes.usr", "text" => "no id here"}
      ]
    }

    :ok = Transcript.append_turn(turn1, mud_ctx)

    state2 = loop_state(entity, mud_ctx, event("no id here", "m-whatever"))
    text = Scrollback.render(state2)

    assert text =~ ~s(jes.usr said: "no id here")
  end

  ## --- PIN (e): heartbeat wakes get scrollback too ---

  test "PIN (e): a heartbeat wake right after a chat turn carries the prior reply", ctx do
    {_prov, sc, _mud_ctx} = resolve_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    cert_cids = messages_cert_cids(ctx, sc, messages_uuid)

    bot_dir = mint_bot_dir(ctx, ["look", "post_message"])
    entity = load_entity(ctx, bot_dir, "camillo.bot")

    test_pid = self()

    common_opts = [
      root_uuid: ctx.mud_root,
      store: ctx.store,
      secret_store: ctx.secrets,
      messages_uuid: messages_uuid,
      cert_cids: cert_cids,
      presence_enabled: false
    ]

    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               event("hey camillo", "m-chat"),
               [
                 client_fn:
                   stub_client([
                     tool_use("t1", "post_message", %{"text" => "hey there"}),
                     end_turn()
                   ])
               ] ++ common_opts
             )

    heartbeat_event = %{"kind" => "heartbeat", "verb" => "heartbeat", "thread_quiet" => true}

    assert {:ok, :end_turn} =
             Worker.run(
               "jes",
               entity,
               heartbeat_event,
               [client_fn: capturing_stub_client(test_pid, [end_turn()])] ++ common_opts
             )

    assert_received {:request, turn2_request}

    text = first_wake_text(turn2_request)
    assert text =~ ~s(You replied: "hey there")
    assert text =~ "You woke on a heartbeat"
  end
end
