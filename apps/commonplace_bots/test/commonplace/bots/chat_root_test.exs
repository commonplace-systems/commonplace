defmodule Commonplace.Bots.ChatRootTest do
  @moduledoc """
  cp-plan #8833 — the CHAT-path twin of `Commonplace.Bots.AutonomousRootTest`
  (CX-k87w). `invoke_worker_chat/4` must thread the ROOM-REGISTERED
  `:root_uuid`/`:cert_cids` (via `Dispatcher.subscribe_room/4`'s opts) into
  the Worker, the same way the autonomous tick threads the REGISTERED
  `mud_root`. `PostMessage.signing_opts/1` must ALSO thread the resulting
  `:cert_cids` (via `state.opts` and/or `state.mud_ctx`) into
  `Commonplace.Chat.Actions.post_message/3`, or a cert-authorized (not
  `trusted_identities`-pinned) bot's reply is silently denied under enforce.

  Deliberately does NOT use `worker_hook` — per lesson #6 ("pin the PATH
  the live actor walks, not the seam beneath it"), `worker_hook`
  intercepts BEFORE `invoke_worker_chat/4` assembles the spawn opts, which
  is exactly why this gap could stay green under a worker_hook-based test.
  Both pins here go through the REAL path: a chat post is landed via
  `Commonplace.Chat.Actions.post_message/3` from a "human" signer, which
  broadcasts the SAME magenta event production code broadcasts
  (`Commonplace.Chat.Actions.broadcast_chain/4`); the REAL `Dispatcher`
  (subscribed to that topic, no worker_hook) receives it, evaluates the
  REAL trigger, and spawns the REAL `Commonplace.Bots.Worker.run/4` via
  `spawn_worker/4`.

  PIN A (permissive): without Gap 1's fix, `invoke_worker_chat/4` never
  threads `:root_uuid`, so `Worker.resolve_mud_context/4` falls back to
  `opts[:root_uuid] || workspace_root()` — both wrong/nil on this test's
  isolated store — `mud_ctx` comes back `nil`, and `look` refuses
  ("You are not in the world.") instead of showing the citizen's
  provisioned Foyer.

  PIN B (REAL enforce): without Gap 2's fix, the bot's `post_message`
  reply is correctly bot-SIGNED but carries no `capability_proof` (its
  `{:docs, [messages_uuid]}` cert never reaches
  `Commonplace.Chat.Actions.commit_entry/5`) — `Commonplace.Trust.authorized?/5`
  denies it, and the reply text never lands in `_messages` at all.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Citizen, Dispatcher, TgRoom}
  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_chatroot_#{n}")
    File.mkdir_p!(dir)
    store = :"chatroot_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"chatroot_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"chatroot_tss_#{n}",
       pending_imports_name: :"chatroot_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_chatroot_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"chatroot_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    test_pid = self()

    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Commonplace.Bots.Dispatcher,
           [rate_limit_enabled: false, store: store, node_ctx: node_ctx]},
          id: Commonplace.Bots.Dispatcher
        )
      )

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)
      Process.sleep(200)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, []},
            id: Commonplace.Bots.Dispatcher
          )
        )

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

    # DELIBERATELY distinct from any workspace root the Worker might fall
    # back to — a wrong-root resolution is observable, not accidentally
    # correct (same discipline as AutonomousRootTest).
    mud_root = UUID.uuid4()

    CommitStore.create_commit(
      store,
      mud_root,
      Encoding.encode_update(Schema.new_schema()),
      nil,
      %{},
      signing_context: node_ctx
    )

    %{store: store, mud_root: mud_root, secrets: secrets, node_ctx: node_ctx, test_pid: test_pid}
  end

  ## Fixtures (mirrors autonomous_root_test.exs conventions)

  defp mint_signed_text_doc(store, node_ctx, name, body) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil, %{}, signing_context: node_ctx)
    uuid
  end

  # Minimal .bot CHARTER dir — persona.md + trigger.regex + bot.json, ALL
  # node-signed (PIN B runs under REAL enforce — a plain `mint_text_doc/3`
  # unsigned commit would be DENIED once the describe-level setup flips
  # `local_write_gate: :enforce`, for reasons unrelated to either gap this
  # file pins; a real charter is node-provisioned content anyway).
  defp mint_bot_dir(store, node_ctx) do
    schema =
      Schema.new_schema()
      |> Schema.add_file(
        "persona.md",
        mint_signed_text_doc(store, node_ctx, "persona.md", "I am camillo.")
      )
      |> Schema.add_file(
        "trigger.regex",
        mint_signed_text_doc(store, node_ctx, "trigger.regex", "(?i)@camillo")
      )
      |> Schema.add_file(
        "bot.json",
        mint_signed_text_doc(
          store,
          node_ctx,
          "bot.json",
          Jason.encode!(%{"tools" => ["look", "post_message"]})
        )
      )

    uuid = UUID.uuid4()

    CommitStore.create_commit(store, uuid, Encoding.encode_update(schema), nil, %{},
      signing_context: node_ctx
    )

    uuid
  end

  defp tool_use(id, name, input) do
    %{
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      ],
      "usage" => %{"output_tokens" => 5}
    }
  end

  defp end_turn(text \\ "ok") do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  # Call 1: emit the tool_use. Call 2: capture the request the Worker sends
  # back (carries the tool_result), then end the turn.
  defp stub_client(test_pid, tool_name, tool_input) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn request ->
      case Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end) do
        1 ->
          {:ok, tool_use("t1", tool_name, tool_input)}

        _ ->
          send(test_pid, {:worker_request, request})
          {:ok, end_turn()}
      end
    end
  end

  defp reload(store, messages_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, messages_uuid)
    Messages.materialize(doc)
  end

  describe "PIN A — chat-path root threading (permissive)" do
    test "a chat-triggered look sees the REGISTERED room root_uuid, not the workspace root",
         ctx do
      {:ok, prov} =
        Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

      bot_dir = mint_bot_dir(ctx.store, ctx.node_ctx)

      {:ok, room} = TgRoom.ensure(citizen_ctx(ctx, prov), "jes", entity_dir_uuid: bot_dir)

      :ok =
        Dispatcher.subscribe_room("jes", room.room_dir_uuid, room.messages_uuid,
          root_uuid: ctx.mud_root,
          secret_store: ctx.secrets,
          client_fn: stub_client(ctx.test_pid, "look", %{})
        )

      # A REAL human chat post, through the REAL Actions.post_message path
      # (the same primitive every chat client uses) — generates the SAME
      # magenta event production posting generates.
      assert {:ok, _} =
               Actions.post_message(room.messages_uuid, "@camillo look around",
                 room: "jes",
                 signer_id: "jes-human-signer",
                 author_path: "jes.usr",
                 store: ctx.store
               )

      assert_receive {:worker_request, request}, 5_000

      [_initial, _assistant_msg, user_msg] = request.messages
      [%{"type" => "tool_result"} = tool_result] = user_msg["content"]

      refute tool_result["is_error"] == true,
             "look tool errored: #{inspect(tool_result["content"])}"

      text = tool_result["content"]

      # RED signature (pre-Gap-1): "You are not in the world." — mud_ctx nil
      # because root_uuid never reached Worker.run/4.
      refute text =~ "not in the world"
      assert text =~ "Foyer"
    end
  end

  describe "PIN B — reply-through-the-real-tool under REAL enforce" do
    setup do
      old_trust = Application.get_env(:commonplace, :trust)
      old_gate = Application.get_env(:commonplace, :local_write_gate)

      Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

      Application.put_env(:commonplace, :local_write_gate, :enforce)

      on_exit(fn ->
        case old_trust do
          nil -> Application.delete_env(:commonplace, :trust)
          v -> Application.put_env(:commonplace, :trust, v)
        end

        case old_gate do
          nil -> Application.delete_env(:commonplace, :local_write_gate)
          v -> Application.put_env(:commonplace, :local_write_gate, v)
        end
      end)

      :ok
    end

    test "the bot's post_message reply LANDS in the zoned _messages doc, author-signed by the bot",
         ctx do
      {:ok, prov} =
        Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

      bot_dir = mint_bot_dir(ctx.store, ctx.node_ctx)

      cctx = citizen_ctx(ctx, prov)
      {:ok, room} = TgRoom.ensure(cctx, "jes", entity_dir_uuid: bot_dir)

      # The docs-scoped write cert (C4 / CX-cy80 mechanism — the bot's
      # ordinary {:subtree, home} citizenship cert cannot cover the
      # array-content `_messages` doc) — this is the cert Gap 2 threads.
      {:ok, sc} =
        BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
          secret_store: ctx.secrets
        )

      {:ok, cap} =
        TgRoom.issue_write_cert({sc.identity_uuid, sc.public_key}, room.messages_uuid,
          store: ctx.store
        )

      :ok = CommitStore.store_capability(ctx.store, cap)
      bot_signer_id = Signing.signer_id(sc.identity_uuid, sc.public_key)

      :ok =
        Dispatcher.subscribe_room("jes", room.room_dir_uuid, room.messages_uuid,
          root_uuid: ctx.mud_root,
          cert_cids: [cap.id],
          secret_store: ctx.secrets,
          client_fn: stub_client(ctx.test_pid, "post_message", %{"text" => "hello from camillo"})
        )

      # The triggering human post must ALSO land under enforce — node-signed
      # (auto-trusted by construction), so this step isn't itself the pin.
      assert {:ok, _} =
               Actions.post_message(room.messages_uuid, "@camillo reply please",
                 room: "jes",
                 signer_id:
                   Signing.signer_id(ctx.node_ctx.identity_uuid, ctx.node_ctx.public_key),
                 author_path: "jes.usr",
                 signing_context: ctx.node_ctx,
                 store: ctx.store
               )

      assert_receive {:worker_request, request}, 5_000

      # The tool_result the Worker sent back to the model — assert it
      # was NOT an error before checking the doc, so a regression here
      # fails with the actual reason instead of a bare "entry missing".
      [_initial, _assistant_msg, user_msg] = request.messages
      [%{"type" => "tool_result"} = tool_result] = user_msg["content"]

      refute tool_result["is_error"] == true,
             "post_message tool errored: #{inspect(tool_result["content"])}"

      materialized = reload(ctx.store, room.messages_uuid)
      entry = Enum.find(materialized, &(&1["text"] == "hello from camillo"))

      refute is_nil(entry), "bot's reply never landed in _messages (RED signature: Gap 2 unfixed)"
      assert entry["author_signer_id"] == bot_signer_id
    end
  end

  # The bot's own ctx (home_room_uuid/signing_context/cert_cids/signer_id),
  # the same shape `Commonplace.Bots.NoteDoc`/`TgRoom` take.
  defp citizen_ctx(ctx, %{home_room_uuid: home_room_uuid}) do
    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, %{cert_cids: cert_cids}} =
      Commonplace.MUD.Citizenship.ensure(
        sc.identity_uuid,
        sc.public_key,
        "camillo",
        ctx.mud_root,
        ctx.store
      )

    %{
      store: ctx.store,
      home_room_uuid: home_room_uuid,
      signing_context: sc,
      cert_cids: cert_cids,
      signer_id: Signing.signer_id(sc.identity_uuid, sc.public_key)
    }
  end
end
