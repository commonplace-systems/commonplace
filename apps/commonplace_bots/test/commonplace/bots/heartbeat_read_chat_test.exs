defmodule Commonplace.Bots.HeartbeatReadChatTest do
  @moduledoc """
  CX-0xt0 — live regression from the Camillo batch (part 4): a heartbeat
  wake calling `read_chat` crashed the whole worker Task with a `KeyError`
  (`Keyword.fetch!(state.opts, :messages_uuid)`), because the autonomous
  spawn path never threaded `:messages_uuid` at all — only the CHAT path
  did. Pre-batch this was latent (a heartbeat turn had no reason to read
  chat); part 4 gave heartbeat wakes real chat context and a bot reaching
  for `read_chat` hit it live.

  These tests drive the REAL production dispatch path — `worker_hook: nil`
  (the default; NOT the 3-arity test-hook shortcut every other dispatcher
  test uses, which bypasses `invoke_worker`'s heartbeat-opts-merging
  clause entirely) — so `Commonplace.Bots.Dispatcher.spawn_worker/4`
  genuinely runs, with a stubbed `client_fn` threaded through
  `register_autonomous_bot/5`'s own `opts` (the SAME channel
  `:secret_store` already rides, per that function's own moduledoc).

  Pins authored FROM THE SPEC (lesson #8): (a) a real heartbeat wake with
  `chat_rooms` registered AND the room subscribed — `messages_uuid` reaches
  the spawn opts, `read_chat` returns real thread content, the turn
  completes, the transcript appends — RED against the pre-fix dispatcher
  (a bare `KeyError` killed the Task, verified below, restored after);
  (b) a heartbeat wake with NO subscribed room — `read_chat` degrades to
  its honest refusal instead of crashing, and the turn STILL completes
  and the transcript STILL appends (part (c), "chat-path read_chat
  unchanged-green," is the untouched `read_tools_test.exs` file — not
  duplicated here).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Agenda, Citizen, Dispatcher, MudContext, Transcript}
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_hbrc_#{n}")
    File.mkdir_p!(dir)
    store = :"hbrc_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"hbrc_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"hbrc_tss_#{n}",
       pending_imports_name: :"hbrc_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_hbrc_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"hbrc_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # NO worker_hook — the REAL production `spawn_worker/4` path, so
    # `invoke_worker/4`'s heartbeat-opts-merging clause actually runs
    # (every OTHER dispatcher test's 3-arity hook bypasses it entirely).
    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Dispatcher, [rate_limit_enabled: false, store: store, node_ctx: node_ctx]},
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

  defp tool_result_content(request, tool_use_id) do
    request
    |> Map.get(:messages, [])
    |> Enum.find_value(fn msg ->
      msg
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.find_value(fn
        %{"tool_use_id" => ^tool_use_id, "content" => content} -> content
        _ -> nil
      end)
    end)
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition never became true within the deadline")

      true ->
        Process.sleep(20)
        wait_until(fun, deadline)
    end
  end

  ## ---- PIN (a): messages_uuid reaches the spawn opts; read_chat works; turn completes ----

  test "PIN (a): a heartbeat wake with a subscribed room threads messages_uuid — read_chat works, turn completes, transcript appends",
       ctx do
    {_prov, _sc, mud_ctx} = provision_camillo(ctx)
    messages_uuid = mint_messages_doc(ctx)
    room_dir = mint_room_dir(ctx)

    :ok = Dispatcher.subscribe_room("jes", room_dir, messages_uuid)

    {:ok, _} =
      Actions.post_message(messages_uuid, "earlier chat content",
        room: "jes",
        signer_id: "jes-human-signer",
        author_path: "jes.usr",
        store: ctx.store
      )

    bot_dir = mint_bot_dir(ctx, ["read_chat"])
    test_pid = self()

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets,
        chat_rooms: ["jes"],
        client_fn:
          capturing_stub_client(test_pid, [
            tool_use("t1", "read_chat", %{}),
            end_turn()
          ])
      )

    tick("camillo")

    # Round 1 (initial request) — proves the Task started at all.
    assert_receive {:request, _round1}, 2_000
    # Round 2 (after read_chat's tool_result landed in history) — proves
    # the worker did NOT crash on the missing key: this message only
    # arrives if `handle_response/5` successfully processed round 1's
    # tool_use and looped back for another response.
    assert_receive {:request, round2}, 2_000

    read_chat_result = tool_result_content(round2, "t1")
    refute is_nil(read_chat_result)
    assert read_chat_result =~ "earlier chat content"
    refute read_chat_result =~ "you have no chat thread"

    # The turn completed and the transcript actually appended — the crash
    # this bug caused meant NEITHER ever happened.
    wait_until(fn -> Transcript.read(mud_ctx) != [] end)
    [entry] = Transcript.read(mud_ctx)
    assert entry["wake"] == "heartbeat"

    assert Enum.any?(entry["events"], fn e ->
             e["type"] == "tool_call" and e["tool"] == "read_chat"
           end)
  end

  ## ---- PIN (b): no subscribed room -> honest refusal, turn still completes ----

  test "PIN (b): a heartbeat wake with NO subscribed room — read_chat degrades honestly, turn still completes, transcript still appends",
       ctx do
    {_prov, _sc, mud_ctx} = provision_camillo(ctx)

    # A non-empty agenda gives the tick a reason to wake — the point of
    # this pin is "no subscribed chat room," decoupled from "no reason to
    # wake at all" (empty agenda + quiet-by-absence would just SKIP, never
    # reaching read_chat, and wouldn't test this bug).
    :ok = Agenda.append(%{"text" => "something to do"}, mud_ctx)

    # Deliberately NO subscribe_room — chat_rooms names a room that is
    # simply never subscribed, so state.rooms has nothing for it.
    bot_dir = mint_bot_dir(ctx, ["read_chat"])
    test_pid = self()

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets,
        chat_rooms: ["jes"],
        client_fn:
          capturing_stub_client(test_pid, [
            tool_use("t1", "read_chat", %{}),
            end_turn()
          ])
      )

    tick("camillo")

    assert_receive {:request, _round1}, 2_000
    assert_receive {:request, round2}, 2_000

    read_chat_result = tool_result_content(round2, "t1")
    assert read_chat_result == "(you have no chat thread here)"

    wait_until(fn -> Transcript.read(mud_ctx) != [] end)
    [entry] = Transcript.read(mud_ctx)
    assert entry["wake"] == "heartbeat"

    assert Enum.any?(entry["events"], fn e ->
             e["type"] == "error" and e["tool"] == "read_chat"
           end)
  end
end
