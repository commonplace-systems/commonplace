defmodule Commonplace.Bots.AllowlistTest do
  @moduledoc """
  Camillo C3a — the ALLOWLISTED TOOL REGISTRY (authority boundary, ⛩).

  Proves the default-closed charter gate:

    * an entity with no `"tools"` charter (or no `bot.json`) gets `[]`;
    * a NODE-signed `bot.json` charter is honored verbatim;
    * a SELF-ESCALATION — an entity-key-signed edit that widens the
      charter — is refused (`resolve/4` fails closed to `[]`), because the
      LATEST commit signer is now the entity, not a grantor. This is the
      non-vacuous pin: "you cannot write your own charter."
    * refusals are SANITIZED (`"not allowlisted"`, no tool enumeration);
    * the allowlist is NEVER sourced from spawn/dispatcher opts.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Allowlist
  alias Commonplace.Bots.Entity
  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.Worker.Tools
  alias Commonplace.Crypto.{NodeIdentity, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_allowlist_#{n}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_allowlist_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"cp_bots_allowlist_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()

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
    root = mint_doc(Schema.new_schema())

    %{store: CommitStoreClient, secrets: secrets, node_ctx: node_ctx, root: root}
  end

  # ---- fixture helpers ----------------------------------------------------

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

  # A text doc whose GENESIS commit is signed by `ctx`.
  defp mint_signed_text_doc(name, body, ctx) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)

    CommitStore.create_commit(
      Commonplace.Store.CommitStore,
      uuid,
      update,
      nil,
      %{},
      signing_context: ctx
    )

    uuid
  end

  # Replace bot.json's whole content with `new_body` in a chained commit
  # signed by `ctx` — models an agent editing its own charter file.
  defp signed_edit_bot_json(botjson_uuid, new_body, ctx) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, botjson_uuid)
    old = ContentType.get_content(doc) || ""
    doc = if old == "", do: doc, else: ContentType.delete_text(doc, 0, String.length(old))
    doc = ContentType.insert_text(doc, 0, new_body)
    update = Yelixer.Encoding.encode_update(doc)

    CommitStore.create_chained_commit(
      Commonplace.Store.CommitStore,
      botjson_uuid,
      update,
      %{},
      signing_context: ctx
    )

    :ok
  end

  # Build a *.bot dir. `bot_json` is either nil (omit bot.json) or a
  # {body, signer_ctx | :unsigned} tuple describing the bot.json doc.
  defp mint_bot_dir(bot_json) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "I am alice."))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", "(?i)@alice"))

    schema =
      case bot_json do
        nil ->
          schema

        {body, :unsigned} ->
          Schema.add_file(schema, "bot.json", mint_text_doc("bot.json", body))

        {body, ctx} ->
          Schema.add_file(schema, "bot.json", mint_signed_text_doc("bot.json", body, ctx))
      end

    mint_doc(schema)
  end

  defp load_entity(uuid) do
    {:ok, entity} = Entity.load(CommitStoreClient, uuid, "alice.bot")
    entity
  end

  defp entity_sc(ctx) do
    {:ok, %SigningContext{} = sc} =
      BotIdentity.resolve_signing_context("alice", ctx.root, CommitStoreClient,
        secret_store: ctx.secrets
      )

    sc
  end

  # Attach a telemetry handler that forwards charter_rejected events to
  # the test process; detached on exit.
  defp capture_rejections do
    ref = make_ref()
    handler_id = {:allowlist_reject, ref}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:commonplace, :bots, :allowlist, :charter_rejected],
      fn _event, _measure, meta, _cfg -> send(test_pid, {:charter_rejected, ref, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp tool_state(entity, allowlist, opts) do
    %{
      entity: entity,
      room: "demo",
      event: %{"message_id" => "m1"},
      opts: opts,
      allowlist: allowlist,
      signing_context: nil
    }
  end

  # ---- 1. DEFAULT-CLOSED --------------------------------------------------

  describe "default-closed" do
    test "no bot.json at all -> []", ctx do
      entity = load_entity(mint_bot_dir(nil))
      sc = entity_sc(ctx)

      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient) == []
      assert Tools.tool_defs(tool_state(entity, [], [])) == []

      assert {:error, "not allowlisted"} =
               Tools.dispatch(tool_state(entity, [], []), "post_message", %{"text" => "x"})
    end

    test "bot.json present but no \"tools\" field -> []", ctx do
      # node-signed, but the charter grants nothing (no tools key).
      entity = load_entity(mint_bot_dir({~s({"max_calls": 3}), ctx.node_ctx}))
      sc = entity_sc(ctx)

      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient) == []
      assert Tools.tool_defs(tool_state(entity, [], [])) == []
    end

    test "\"tools\" present but not a list of strings -> []", ctx do
      entity = load_entity(mint_bot_dir({~s({"tools": "post_message"}), ctx.node_ctx}))
      sc = entity_sc(ctx)
      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient) == []
    end

    test "nil signing context (no identity) -> [] regardless of charter", ctx do
      entity =
        load_entity(mint_bot_dir({~s({"tools": ["post_message"]}), ctx.node_ctx}))

      assert Allowlist.resolve(entity, nil, CommitStoreClient) == []
    end
  end

  # ---- 2. NODE-SIGNED CHARTER HONORED -------------------------------------

  describe "node-signed charter honored" do
    test "resolve returns exactly the granted tools", ctx do
      body = ~s({"tools": ["post_message", "read_chat"]})
      entity = load_entity(mint_bot_dir({body, ctx.node_ctx}))
      sc = entity_sc(ctx)

      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient) ==
               ["post_message", "read_chat"]
    end

    test "tool_defs offers exactly the granted tools; dispatch honors/refuses", ctx do
      body = ~s({"tools": ["post_message", "read_chat"]})
      entity = load_entity(mint_bot_dir({body, ctx.node_ctx}))
      sc = entity_sc(ctx)
      allow = Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient)

      names = Tools.tool_defs(tool_state(entity, allow, [])) |> Enum.map(& &1["name"])
      assert Enum.sort(names) == ["post_message", "read_chat"]

      # A granted writer proceeds for real (bot-signed post).
      messages_uuid = mint_messages_doc()
      state = %{tool_state(entity, allow, messages_uuid: messages_uuid) | signing_context: sc}
      assert {:ok, json} = Tools.dispatch(state, "post_message", %{"text" => "hi"})
      assert %{"message_id" => _} = Jason.decode!(json)

      # A NON-granted tool is refused even though it is a real module.
      assert {:error, "not allowlisted"} =
               Tools.dispatch(state, "remember", %{"text" => "nope"})
    end
  end

  # ---- 3. SELF-ESCALATION REFUSED (THE PIN, non-vacuous) ------------------

  describe "self-escalation refused" do
    test "entity-signed edit widening the charter fails closed to []", ctx do
      ref = capture_rejections()

      # Start from a valid node-signed charter granting one tool.
      dir = mint_bot_dir({~s({"tools": ["post_message"]}), ctx.node_ctx})
      entity0 = load_entity(dir)
      sc = entity_sc(ctx)

      # Sanity: node-signed charter is honored before the tampering.
      assert Allowlist.resolve(entity0, sc.identity_uuid, CommitStoreClient) == ["post_message"]

      botjson_uuid = Map.fetch!(entity0.children, "bot.json")

      # The agent uses its OWN key to edit its charter, adding "remember".
      :ok =
        signed_edit_bot_json(
          botjson_uuid,
          ~s({"tools": ["post_message", "remember"]}),
          sc
        )

      # Reload: bot_config now shows the widened list — but the LATEST
      # commit is entity-signed, so the whole charter is rejected.
      entity1 = load_entity(dir)
      assert entity1.bot_config["tools"] == ["post_message", "remember"]

      assert Allowlist.resolve(entity1, sc.identity_uuid, CommitStoreClient) == []

      # Fail-closed reason is reported.
      assert_receive {:charter_rejected, ^ref, %{reason: :self_signed}}

      # The "granted" tool (and even the previously-granted one) is refused.
      state = tool_state(entity1, [], [])
      assert {:error, "not allowlisted"} = Tools.dispatch(state, "remember", %{"text" => "x"})
      assert {:error, "not allowlisted"} = Tools.dispatch(state, "post_message", %{"text" => "x"})
      assert Tools.tool_defs(state) == []
    end

    test "an unsigned charter doc is rejected as :unsigned", ctx do
      ref = capture_rejections()
      entity = load_entity(mint_bot_dir({~s({"tools": ["post_message"]}), :unsigned}))
      sc = entity_sc(ctx)

      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient) == []
      assert_receive {:charter_rejected, ^ref, %{reason: :unsigned}}
    end

    test "a charter signed by a foreign non-grantor is :untrusted_grantor", ctx do
      ref = capture_rejections()

      {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()

      foreign = %SigningContext{
        identity_uuid: UUID.uuid4(),
        private_key: priv,
        public_key: pub
      }

      entity = load_entity(mint_bot_dir({~s({"tools": ["post_message"]}), foreign}))
      sc = entity_sc(ctx)

      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient) == []
      assert_receive {:charter_rejected, ^ref, %{reason: :untrusted_grantor}}
    end
  end

  # ---- 4. SANITIZED REFUSAL ----------------------------------------------

  describe "sanitized refusal" do
    test "refusal string is exactly \"not allowlisted\" and lists no tools", ctx do
      body = ~s({"tools": ["read_chat"]})
      entity = load_entity(mint_bot_dir({body, ctx.node_ctx}))
      allow = ["read_chat"]

      assert {:error, msg} =
               Tools.dispatch(tool_state(entity, allow, []), "post_message", %{"text" => "x"})

      assert msg == "not allowlisted"
      refute msg =~ "read_chat"
      refute msg =~ "post_message"
    end
  end

  # ---- 5. ALLOWLIST NOT FROM SPAWN OPTS -----------------------------------

  describe "allowlist provenance is config-doc only" do
    test "planting allowlist:/tools: in resolve opts grants nothing", ctx do
      # No charter doc at all.
      entity = load_entity(mint_bot_dir(nil))
      sc = entity_sc(ctx)

      opts = [allowlist: ["post_message", "remember"], tools: ["post_message"]]
      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient, opts) == []
    end

    test "operator-grantor app-env can extend grantors, but never the entity's own key", ctx do
      body = ~s({"tools": ["post_message"]})

      # A charter signed by an operator identity that we then whitelist.
      {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()
      operator_id = UUID.uuid4()
      operator = %SigningContext{identity_uuid: operator_id, private_key: priv, public_key: pub}

      entity = load_entity(mint_bot_dir({body, operator}))
      sc = entity_sc(ctx)

      old = Application.get_env(:commonplace_bots, :bots_allowlist_grantors)
      Application.put_env(:commonplace_bots, :bots_allowlist_grantors, [operator_id])

      on_exit(fn ->
        case old do
          nil -> Application.delete_env(:commonplace_bots, :bots_allowlist_grantors)
          v -> Application.put_env(:commonplace_bots, :bots_allowlist_grantors, v)
        end
      end)

      assert Allowlist.resolve(entity, sc.identity_uuid, CommitStoreClient) == ["post_message"]

      # But the entity's OWN key is rejected even if someone lists it as a
      # grantor — "never your own key" wins.
      Application.put_env(:commonplace_bots, :bots_allowlist_grantors, [sc.identity_uuid])
      self_entity = load_entity(mint_bot_dir({body, sc}))
      assert Allowlist.resolve(self_entity, sc.identity_uuid, CommitStoreClient) == []
    end
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Commonplace.Chat.Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end
end
