defmodule Commonplace.Bots.TgRoomTest do
  @moduledoc """
  Camillo C4 — `Commonplace.Bots.TgRoom`.

  Runs under `local_write_gate: :enforce` + strict trust (mirrors
  `Commonplace.Bots.CitizenTest`'s setup) so every assertion proves the
  bot's zoned-dir writes genuinely land under the strict gate.

  ## The grounding finding this test file encodes (see `TgRoom`'s moduledoc
  "THE CARVE-RULE WALL" for the full derivation)

  `_messages` is a bare `Commonplace.Chat.Messages.new()` doc —
  `ContentType.create(doc, :array, ...)`. `Commonplace.Trust.doc_zone/2`
  reads a target's zone via `own_zone/1`, which requires
  `ContentType.get_content/1` to return a BINARY JSON string; for `:array`
  content it returns a LIST (`Array.to_list/2`) instead, so the guard never
  matches. This is true of EVERY `_messages` doc, structurally, not a bug in
  this bead's wiring — `doc_zone/2` returns `nil` for `_messages` here for
  the exact same reason it would for any other chat room's `_messages` doc
  in this codebase. `_messages` is therefore deliberately left UNZONED;
  write authority into it is a `{:docs, [messages_uuid]}` capability
  (`TgRoom.issue_write_cert/3`), asserted separately below — never a
  subtree/zone-stamp mechanism.

  The `home/tg/<room>` DIR itself, by contrast, IS a normal zoned child
  (same mechanism `Commonplace.Bots.NoteDoc` uses) — its own entry-adds
  (linking `_messages`, linking `camillo.bot`) land under the bot's
  ordinary `{:subtree, home}` citizenship cert, asserted here too.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{NoteDoc, TgRoom}
  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Citizenship, Schemas}
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_tgroom_#{n}")
    File.mkdir_p!(dir)
    store = :"tgroom_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"tgroom_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"tgroom_tss_#{n}",
       pending_imports_name: :"tgroom_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_tgroom_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"tgroom_secrets_#{n}"
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

    mud_root = UUID.uuid4()

    assert %Commonplace.Store.Commit{} =
             CommitStore.create_commit(
               store,
               mud_root,
               Encoding.encode_update(Schema.new_schema()),
               nil,
               %{},
               signing_context: node_ctx
             )

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", mud_root, store, secret_store: secrets)

    {:ok, %{home_room_uuid: home_room_uuid, cert_cids: cert_cids}} =
      Citizenship.ensure(sc.identity_uuid, sc.public_key, "camillo", mud_root, store)

    ctx = %{
      store: store,
      signing_context: sc,
      signer_id: Signing.signer_id(sc.identity_uuid, sc.public_key),
      cert_cids: cert_cids,
      home_room_uuid: home_room_uuid
    }

    {:ok, entity_dir_uuid} = NoteDoc.ensure_zoned_dir(home_room_uuid, "entity", ~s({}), ctx)

    %{
      store: store,
      secrets: secrets,
      node_ctx: node_ctx,
      ctx: ctx,
      entity_dir_uuid: entity_dir_uuid
    }
  end

  test "ensure mints a zoned room dir + a bare _messages doc + a bot-entity link", ctx do
    assert {:ok, %{room_dir_uuid: room_dir_uuid, messages_uuid: messages_uuid}} =
             TgRoom.ensure(ctx.ctx, "jes", entity_dir_uuid: ctx.entity_dir_uuid)

    # The room dir IS zoned, inheriting the home zone (normal mechanism).
    assert Commonplace.Trust.doc_zone(room_dir_uuid, ctx.store) == ctx.ctx.home_room_uuid

    # `_messages` is linked into the room dir...
    assert {:ok, schema} = Schemas.load_dir_schema(room_dir_uuid, ctx.store)
    assert {:ok, %{node_id: ^messages_uuid}} = Schema.get_entry(schema, "_messages")

    # ...and the bot's entity dir is LINKED (a DAG link, not a copy) —
    # the SAME uuid the caller passed resolves under the new entry name.
    assert {:ok, %{node_id: entity_link}} = Schema.get_entry(schema, "camillo.bot")
    assert entity_link == ctx.entity_dir_uuid

    # THE GROUNDING FINDING: `_messages` structurally carries no zone stamp
    # (see moduledoc) — `doc_zone/2` is nil, not the home root.
    assert Commonplace.Trust.doc_zone(messages_uuid, ctx.store) == nil
  end

  test "ensure is idempotent: same room_name -> same uuids, no duplicate entries", ctx do
    assert {:ok, r1} = TgRoom.ensure(ctx.ctx, "jes", entity_dir_uuid: ctx.entity_dir_uuid)
    assert {:ok, r2} = TgRoom.ensure(ctx.ctx, "jes", entity_dir_uuid: ctx.entity_dir_uuid)

    assert r1 == r2

    assert {:ok, schema} = Schemas.load_dir_schema(r1.room_dir_uuid, ctx.store)
    # __tg_room.json (the dir's own zoned meta) + _messages + camillo.bot
    assert length(Schema.list_entries(schema)) == 3
  end

  test "the room dir's own entry-adds land under enforce via the bot's ordinary subtree cert",
       ctx do
    assert {:ok, %{room_dir_uuid: room_dir_uuid}} =
             TgRoom.ensure(ctx.ctx, "jes", entity_dir_uuid: ctx.entity_dir_uuid)

    bot_signer_id = ctx.ctx.signer_id

    {:ok, schema} = Schemas.load_dir_schema(room_dir_uuid, ctx.store)
    {:ok, %{node_id: messages_uuid}} = Schema.get_entry(schema, "_messages")

    # The LINK commit on room_dir (adding "_messages") is bot-signed — proof
    # this landed via the bot's {:subtree, home} cert, not node authority.
    {:ok, link_commit} = CommitStore.latest_commit(ctx.store, room_dir_uuid)
    assert link_commit.signer_id == bot_signer_id

    # The `_messages` doc's OWN genesis, by contrast, is node-signed (it has
    # no zone for the bot's subtree cert to cover — see moduledoc).
    {:ok, node_pub} = NodeIdentity.public_key()
    {:ok, node_identity} = NodeIdentity.identity()
    node_signer_id = Signing.signer_id(node_identity, node_pub)

    {:ok, genesis_commit} = CommitStore.latest_commit(ctx.store, messages_uuid)
    assert genesis_commit.signer_id == node_signer_id
  end

  test "issue_write_cert mints a {:docs, [messages_uuid]} cert that actually authorizes a post",
       ctx do
    assert {:ok, %{messages_uuid: messages_uuid}} =
             TgRoom.ensure(ctx.ctx, "jes", entity_dir_uuid: ctx.entity_dir_uuid)

    stranger_uuid = UUID.uuid4()
    {stranger_pub, stranger_priv} = Signing.generate_keypair()

    stranger_sc = %SigningContext{
      identity_uuid: stranger_uuid,
      private_key: stranger_priv,
      public_key: stranger_pub
    }

    # No cert at all: the stranger's post is denied.
    assert {:error, _} =
             Commonplace.Chat.Actions.post_message(messages_uuid, "no cert",
               room: "jes",
               signer_id: Signing.signer_id(stranger_uuid, stranger_pub),
               author_path: "stranger",
               signing_context: stranger_sc,
               store: ctx.store
             )

    # issue_write_cert PERSISTS the cert itself now (the live-found bug —
    # see its moduledoc) — no manual `CommitStore.store_capability/2`
    # fixture step here; the pin below (`issue_write_cert persists ...`)
    # proves that directly.
    assert {:ok, cap} =
             TgRoom.issue_write_cert({stranger_uuid, stranger_pub}, messages_uuid,
               store: ctx.store
             )

    cid = cap.id

    assert {:ok, %{message_id: _}} =
             Commonplace.Chat.Actions.post_message(messages_uuid, "with cert",
               room: "jes",
               signer_id: Signing.signer_id(stranger_uuid, stranger_pub),
               author_path: "stranger",
               signing_context: stranger_sc,
               cert_cids: [cid],
               store: ctx.store
             )
  end

  test "issue_write_cert persists the cert — resolvable by cid with NO manual store_capability step",
       ctx do
    assert {:ok, %{messages_uuid: messages_uuid}} =
             TgRoom.ensure(ctx.ctx, "jes", entity_dir_uuid: ctx.entity_dir_uuid)

    stranger_uuid = UUID.uuid4()
    {stranger_pub, _stranger_priv} = Signing.generate_keypair()

    # The direct pin (RED against the old, mint-only helper — see
    # `issue_write_cert`'s moduledoc "The live-found bug this fixed"):
    # persistence happens INSIDE issue_write_cert/3, not as a separate
    # fixture step the caller must remember.
    assert {:ok, cap} =
             TgRoom.issue_write_cert({stranger_uuid, stranger_pub}, messages_uuid,
               store: ctx.store
             )

    assert {:ok, ^cap} = Commonplace.Store.CommitStoreClient.get_capability(ctx.store, cap.id)
  end
end
