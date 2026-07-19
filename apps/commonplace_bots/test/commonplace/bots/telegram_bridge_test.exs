defmodule Commonplace.Bots.TelegramBridgeTest do
  @moduledoc """
  Camillo C4 — `Commonplace.Bots.TelegramBridge`. Runs entirely through a
  fake `Transport` — no HTTP, no Telegram, anywhere in this file. Several
  tests run under `local_write_gate: :enforce` + strict trust (the
  recurring "dry_run lands the write anyway" trap — see
  `feedback_ci_gate_env_sensitive` — is why enforce is set explicitly, not
  left at the test-default).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.TelegramBridge
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  defmodule FakeTransport do
    @behaviour Commonplace.Bots.TelegramBridge.Transport

    @impl true
    def relay_to_external(test_pid, message) do
      send(test_pid, {:relayed, message})
      {:ok, test_pid}
    end
  end

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_tg_bridge_#{n}")
    File.mkdir_p!(dir)
    store = :"tg_bridge_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"tg_bridge_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"tg_bridge_tss_#{n}",
       pending_imports_name: :"tg_bridge_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_tg_bridge_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"tg_bridge_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
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

    messages_uuid = UUID.uuid4()

    assert %Commonplace.Store.Commit{} =
             CommitStore.create_commit(
               store,
               messages_uuid,
               Encoding.encode_update(Messages.new()),
               nil,
               %{},
               signing_context: node_ctx
             )

    # A "bot" principal, independent of the bridge — mints its own key,
    # gets a {:docs, [messages_uuid]} write cert (the C4 mechanism —
    # see `Commonplace.Bots.TgRoom`'s moduledoc), and can post into the
    # SAME room the bridge mirrors.
    bot_uuid = UUID.uuid4()
    {bot_pub, bot_priv} = Signing.generate_keypair()
    bot_sc = %SigningContext{identity_uuid: bot_uuid, private_key: bot_priv, public_key: bot_pub}
    bot_signer_id = Signing.signer_id(bot_uuid, bot_pub)

    {:ok, bot_cap} =
      Capability.issue(node_ctx, {bot_uuid, bot_pub}, %{
        verbs: [:write],
        scope: {:docs, [messages_uuid]}
      })

    :ok = CommitStore.store_capability(store, bot_cap)

    %{
      store: store,
      secrets: secrets,
      node_ctx: node_ctx,
      messages_uuid: messages_uuid,
      bot_uuid: bot_uuid,
      bot_sc: bot_sc,
      bot_signer_id: bot_signer_id,
      bot_cert_cids: [bot_cap.id]
    }
  end

  defp start_bridge(ctx, extra_opts \\ []) do
    opts =
      [
        room: "jes",
        messages_uuid: ctx.messages_uuid,
        bot_identity_uuid: ctx.bot_signer_id,
        store: ctx.store,
        secret_store: ctx.secrets,
        transport_mod: FakeTransport,
        transport_state: self(),
        interval_ms: :infinity
      ] ++ extra_opts

    {:ok, bridge} = TelegramBridge.start_link(opts)
    bridge
  end

  defp bridge_cert_cids(bridge_identity_uuid, ctx) do
    {:ok, bridge_pub} = Commonplace.Crypto.AgentKeys.ensure(bridge_identity_uuid, ctx.secrets)

    {:ok, cap} =
      Capability.issue(ctx.node_ctx, {bridge_identity_uuid, bridge_pub}, %{
        verbs: [:write],
        scope: {:docs, [ctx.messages_uuid]}
      })

    :ok = CommitStore.store_capability(ctx.store, cap)
    [cap.id]
  end

  defp bot_post(ctx, text) do
    Actions.post_message(ctx.messages_uuid, text,
      room: "jes",
      signer_id: ctx.bot_signer_id,
      author_path: "camillo.bot",
      signing_context: ctx.bot_sc,
      cert_cids: ctx.bot_cert_cids,
      store: ctx.store
    )
  end

  defp reload(ctx), do: reload(ctx.store, ctx.messages_uuid)

  defp reload(store, messages_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, messages_uuid)
    Messages.materialize(doc)
  end

  describe "ENFORCE: inbound cert-gated landing" do
    test "a bridge-signed inbound post WITH its cert LANDS under enforce", ctx do
      bridge = start_bridge(ctx, owner_chat_id: 555)
      identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      cert_cids = bridge_cert_cids(identity_uuid, ctx)

      # Re-mint the bridge WITH the cert now that we know its identity —
      # cert issuance is provision-time, so pass it at start.
      TelegramBridge.pause(bridge)
      bridge2 = start_bridge(ctx, owner_chat_id: 555, cert_cids: cert_cids)

      send(
        bridge2,
        {:external_message, %{nick: "jes", handle: "jes", text: "hello camillo", chat_id: 555}}
      )

      _ = TelegramBridge.status(bridge2)

      materialized = reload(ctx)
      assert Enum.any?(materialized, &(&1["text"] == "hello camillo"))
    end

    test "the SAME post WITHOUT cert_cids is DENIED", ctx do
      bridge = start_bridge(ctx, owner_chat_id: 555)

      send(
        bridge,
        {:external_message, %{nick: "jes", handle: "jes", text: "should be denied", chat_id: 555}}
      )

      _ = TelegramBridge.status(bridge)

      materialized = reload(ctx)
      refute Enum.any?(materialized, &(&1["text"] == "should be denied"))
    end
  end

  describe "ENFORCE: the bot's own reply lands" do
    test "the bot's citizen-signed post (its own {:docs} cert) LANDS in _messages", ctx do
      assert {:ok, %{message_id: _}} = bot_post(ctx, "reply from camillo")

      materialized = reload(ctx)
      assert Enum.any?(materialized, &(&1["text"] == "reply from camillo"))
    end
  end

  describe "CRITERION-3 FILTER" do
    test "only the bot-signed entry is relayed; cursor advances past all three", ctx do
      bridge = start_bridge(ctx, owner_chat_id: 1)

      # bot-signed
      {:ok, %{message_id: bot_msg_id}} = bot_post(ctx, "bot says hi")

      # bridge-signed (posted directly, bypassing the bridge's own inbound
      # path — simulates the bridge's own inbound-relayed history)
      identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      {:ok, bridge_pub} = Commonplace.Crypto.AgentKeys.ensure(identity_uuid, ctx.secrets)

      {:ok, bridge_sc} =
        Commonplace.Crypto.AgentKeys.signing_context_for(identity_uuid, ctx.secrets)

      {:ok, bridge_cap} =
        Capability.issue(ctx.node_ctx, {identity_uuid, bridge_pub}, %{
          verbs: [:write],
          scope: {:docs, [ctx.messages_uuid]}
        })

      :ok = CommitStore.store_capability(ctx.store, bridge_cap)

      {:ok, %{message_id: _bridge_msg_id}} =
        Actions.post_message(ctx.messages_uuid, "bridge relayed this",
          room: "jes",
          signer_id: identity_uuid,
          author_path: "someone (via Telegram)",
          signing_context: bridge_sc,
          cert_cids: [bridge_cap.id],
          store: ctx.store
        )

      # third-party-signed
      third_uuid = UUID.uuid4()
      {third_pub, third_priv} = Signing.generate_keypair()

      third_sc = %SigningContext{
        identity_uuid: third_uuid,
        private_key: third_priv,
        public_key: third_pub
      }

      {:ok, third_cap} =
        Capability.issue(ctx.node_ctx, {third_uuid, third_pub}, %{
          verbs: [:write],
          scope: {:docs, [ctx.messages_uuid]}
        })

      :ok = CommitStore.store_capability(ctx.store, third_cap)

      {:ok, %{message_id: _third_msg_id}} =
        Actions.post_message(ctx.messages_uuid, "third party message",
          room: "jes",
          signer_id: Signing.signer_id(third_uuid, third_pub),
          author_path: "someone_else.usr",
          signing_context: third_sc,
          cert_cids: [third_cap.id],
          store: ctx.store
        )

      assert {:ok, %{relayed: 1}} = TelegramBridge.tick_now(bridge)
      assert_received {:relayed, %{text: "bot says hi"}}
      refute_received {:relayed, %{text: "bridge relayed this"}}
      refute_received {:relayed, %{text: "third party message"}}

      assert %{last_cursor: last_cursor} = TelegramBridge.status(bridge)
      refute last_cursor == bot_msg_id
      # cursor is past ALL THREE entries (the last one appended)
      materialized = reload(ctx)
      assert last_cursor == List.last(materialized)["id"]
    end
  end

  describe "ATTRIBUTION" do
    test "inbound produces author_signer_id == bridge identity AND author_path == nick (via Telegram)",
         ctx do
      identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      cert_cids = bridge_cert_cids(identity_uuid, ctx)
      bridge = start_bridge(ctx, owner_chat_id: 42, cert_cids: cert_cids)

      send(
        bridge,
        {:external_message, %{nick: "jes", handle: "jes", text: "attribution check", chat_id: 42}}
      )

      _ = TelegramBridge.status(bridge)

      materialized = reload(ctx)
      entry = Enum.find(materialized, &(&1["text"] == "attribution check"))

      assert entry["author_signer_id"] == identity_uuid
      assert entry["author_path"] == "jes (via Telegram)"

      # The bot's own identity is NOT the signer of this inbound post.
      refute entry["author_signer_id"] == ctx.bot_signer_id
      refute entry["author_signer_id"] == ctx.bot_uuid
    end
  end

  describe "SEPARATE PRINCIPAL" do
    test "bridge identity_uuid != bot identity_uuid != node identity", ctx do
      bridge_identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      {:ok, node_identity} = NodeIdentity.identity()

      refute bridge_identity_uuid == ctx.bot_uuid
      refute bridge_identity_uuid == node_identity
      refute ctx.bot_uuid == node_identity
    end
  end

  describe "chat_id binding: owner_chat_id mode" do
    test "stranger chat_id dropped + no bind when owner_chat_id is set", ctx do
      identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      cert_cids = bridge_cert_cids(identity_uuid, ctx)
      bridge = start_bridge(ctx, owner_chat_id: 100, cert_cids: cert_cids)

      send(
        bridge,
        {:external_message,
         %{nick: "stranger", handle: "stranger", text: "unwelcome", chat_id: 999}}
      )

      _ = TelegramBridge.status(bridge)

      refute Enum.any?(reload(ctx), &(&1["text"] == "unwelcome"))
      assert %{bound: true} = TelegramBridge.status(bridge)
    end

    test "outbound goes only to the bound chat_id", ctx do
      identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      cert_cids = bridge_cert_cids(identity_uuid, ctx)
      bridge = start_bridge(ctx, owner_chat_id: 100, cert_cids: cert_cids)

      bot_post(ctx, "outbound to bound chat")
      assert {:ok, %{relayed: 1}} = TelegramBridge.tick_now(bridge)
      assert_received {:relayed, %{text: "outbound to bound chat", chat_id: "100"}}
    end
  end

  describe "chat_id binding: owner_handle mode" do
    test "handle mismatch dropped, matching handle binds, when only owner_handle set", ctx do
      identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      cert_cids = bridge_cert_cids(identity_uuid, ctx)
      bridge = start_bridge(ctx, owner_handle: "Jes5199", cert_cids: cert_cids)

      send(
        bridge,
        {:external_message, %{nick: "stranger", handle: "not_jes", text: "nope", chat_id: 1}}
      )

      _ = TelegramBridge.status(bridge)
      refute Enum.any?(reload(ctx), &(&1["text"] == "nope"))
      assert %{bound: false} = TelegramBridge.status(bridge)

      # Case-insensitive match binds.
      send(
        bridge,
        {:external_message, %{nick: "Jes", handle: "jes5199", text: "hi it's me", chat_id: 777}}
      )

      _ = TelegramBridge.status(bridge)
      assert Enum.any?(reload(ctx), &(&1["text"] == "hi it's me"))
      assert %{bound: true} = TelegramBridge.status(bridge)

      # A later message from a DIFFERENT chat_id (even with the right
      # handle claimed) never rebinds.
      send(
        bridge,
        {:external_message, %{nick: "Jes", handle: "jes5199", text: "second chat", chat_id: 888}}
      )

      _ = TelegramBridge.status(bridge)
      refute Enum.any?(reload(ctx), &(&1["text"] == "second chat"))
    end
  end

  describe "chat_id binding: neither configured" do
    test "nothing binds, inbound never posts", ctx do
      bridge = start_bridge(ctx)

      send(
        bridge,
        {:external_message, %{nick: "anyone", handle: "anyone", text: "never lands", chat_id: 1}}
      )

      _ = TelegramBridge.status(bridge)

      refute Enum.any?(reload(ctx), &(&1["text"] == "never lands"))
      assert %{bound: false} = TelegramBridge.status(bridge)
    end
  end

  describe "kill-switch" do
    test "paused bridge relays nothing either way; resume restores", ctx do
      identity_uuid = TelegramBridge.bridge_identity_uuid("jes")
      cert_cids = bridge_cert_cids(identity_uuid, ctx)
      bridge = start_bridge(ctx, owner_chat_id: 1, cert_cids: cert_cids)

      :ok = TelegramBridge.pause(bridge)
      assert %{paused: true} = TelegramBridge.status(bridge)

      bot_post(ctx, "while paused")

      send(
        bridge,
        {:external_message, %{nick: "jes", handle: "jes", text: "also while paused", chat_id: 1}}
      )

      assert {:ok, :paused} = TelegramBridge.tick_now(bridge)
      refute_received {:relayed, _}
      refute Enum.any?(reload(ctx), &(&1["text"] == "also while paused"))

      :ok = TelegramBridge.resume(bridge)
      assert %{paused: false} = TelegramBridge.status(bridge)

      assert {:ok, %{relayed: 1}} = TelegramBridge.tick_now(bridge)
      assert_received {:relayed, %{text: "while paused"}}
    end
  end
end
