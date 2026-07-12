defmodule Commonplace.MUD.OrlmInteractableReauthorTest do
  @moduledoc """
  CX-orlm — REPRODUCE-FIRST (plan review pending). The Facade sibling of the
  CX-55o3 presence-oracle-fragility class.

  `Facade.put_state` (an interactable's verb effect) elevates a non-owner
  visitor's write to the OBJECT-OWNER (node, for curated content) via
  `object_owner_authority/2`, which gates on `node_owned?(meta_child)` — and
  `node_owned?` reads the meta child's **LATEST-commit signer** (facade.ex:1576).
  So any later, legitimately-authorized NON-node commit to the meta child (an
  `@desc`/`@name` edit, or a co-curator's write) flips the latest signer off the
  node → `object_owner_authority` returns `:none` → the visitor's write runs
  invoker-signed → the enforce gate refuses it → the interactable BRICKS for
  every visitor, even though the object is still curated/node-owned.

  This test reproduces that break under `:enforce`:
    1. A curated (node-genesis-meta) interactable in a shared room, with a
       node-authored `spin` verb (`put_state spun_by = actor_name`).
    2. Visitor A spins it → node-elevated (meta latest == node) → state lands.
    3. A cert-holding editor `@desc`s the object (an AUTHORIZED non-node write) →
       the meta child's latest signer flips to the editor.
    4. Visitor B spins it → CURRENTLY refused (`object_owner_authority` :none,
       the meta latest is no longer node) → state does NOT update.

  Step 4 asserts the DESIRED behavior (the visitor's spin still works on a
  still-curated object), so this test is RED against the fragile
  latest-signer oracle and turns GREEN once the fix judges node-ownership by
  the meta child's GENESIS signer (frozen node-signed at `create_meta_doc`) plus
  a zone-appropriateness guard (curated/node-owned zone only — never
  over-elevating a visitor's write onto a player @created object). The predicate
  is plan's to rule (separate trust review).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Green.Bursar
  alias Commonplace.MUD.{Parser, Schemas, Sections, SignedWrite, VerbSource, Verbs, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_orlm_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"orlm_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"orlm_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"orlm_tss_#{n}",
       pending_imports_name: :"orlm_pi_#{n}"}
    )

    {root_pub, root_priv} = Signing.generate_keypair()
    root_identity = "orlm-root-#{n}"
    root_ctx = %SigningContext{identity_uuid: root_identity, private_key: root_priv, public_key: root_pub}

    {editor_pub, editor_priv} = Signing.generate_keypair()
    editor_identity = "orlm-editor-#{n}"
    editor_ctx = %SigningContext{identity_uuid: editor_identity, private_key: editor_priv, public_key: editor_pub}

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{
        root_identity => Signing.encode_key(root_pub),
        editor_identity => Signing.encode_key(editor_pub)
      }
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    case GenServer.whereis(Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} = Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)
    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "The Observatory", description: "a domed room"}),
        store,
        signing_context: node_ctx
      )

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      room: room,
      root_ctx: root_ctx,
      editor_identity: editor_identity,
      editor_pub: editor_pub,
      editor_ctx: editor_ctx
    }
  end

  # ---- helpers ----

  defp node_object!(store, room, node_ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: node_ctx
      )

    {:ok, schema} = Schemas.load_dir_schema(room, store)
    schema = Schema.add_directory(schema, "#{name}.obj", uuid)
    {metadata, commit_opts} = SignedWrite.opts_for(room, store: store, signing_context: node_ctx)
    _ = CommitStoreClient.create_chained_commit(store, room, Encoding.encode_update(schema), metadata, commit_opts)
    uuid
  end

  defp visitor_ctx(store, room, name) do
    {pub, priv} = Signing.generate_keypair()
    id = "visitor-#{name}-#{:rand.uniform(1_000_000_000)}"

    %{
      player_name: name,
      player_uuid: UUID.uuid4(),
      player_dir_uuid: UUID.uuid4(),
      inventory_uuid: UUID.uuid4(),
      current_room_uuid: room,
      presence_filename: "#{name}.usr",
      root_uuid: UUID.uuid4(),
      store: store,
      signing_context: %SigningContext{identity_uuid: id, private_key: priv, public_key: pub},
      signer_id: nil,
      cert_cids: []
    }
  end

  defp spun_by(store, obj) do
    {:ok, schema} = Schemas.load_dir_schema(obj, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.object_filename())
    {:ok, doc} = DocBuilder.reconstruct_doc(store, entry.node_id)
    get_in(Jason.decode!(ContentType.get_content(doc)), ["state", "spun_by"])
  end

  defp meta_latest_signer(store, obj) do
    {:ok, child} = World.meta_doc_uuid(obj, Schemas.object_filename(), store)
    {:ok, commit} = CommitStoreClient.latest_commit(store, child)

    case Signing.parse_signer_id(commit.signer_id || "") do
      {:ok, id, _} -> id
      _ -> nil
    end
  end

  test "a curated interactable stays visitor-usable after an authorized @desc re-chains its meta child",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         room: room,
         root_ctx: root_ctx,
         editor_identity: editor_identity,
         editor_pub: editor_pub,
         editor_ctx: editor_ctx
       } do
    orrery = node_object!(store, room, node_ctx, "orrery")

    # Node-authored interactable verb: whoever spins it stamps their own name.
    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "spun_by", Commonplace.MUD.World.Facade.actor_name(world))|
    assert :ok = VerbSource.save_safe_verb(orrery, "spin", body, [orrery], store, signing_context: node_ctx)

    # Meta child starts node-owned (genesis + latest are the node).
    assert meta_latest_signer(store, orrery) == node_identity

    # (1) BASELINE — Visitor A spins the curated object: elevated to node → lands.
    assert :ok = Verbs.dispatch(Parser.parse("spin orrery"), visitor_ctx(store, room, "ada"))
    assert spun_by(store, orrery) == "ada"

    # (2) An AUTHORIZED non-node curator @descs the object. A section cert over
    # the object's meta child lets the editor write it invoker-signed.
    {:ok, child} = World.meta_doc_uuid(orrery, Schemas.object_filename(), store)

    {:ok, cap} =
      Sections.issue_section(root_ctx, {editor_identity, editor_pub}, [child],
        store: store,
        verbs: [:write]
      )

    assert :ok =
             World.set_meta(orrery, Schemas.object_filename(), "description", "an ornate brass orrery",
               store,
               signing_context: editor_ctx,
               cert_cids: [cap.id]
             )

    # The re-chain flipped the meta child's LATEST signer off the node.
    assert meta_latest_signer(store, orrery) == editor_identity

    # (3) Visitor B spins the SAME still-curated object. DESIRED: it still works
    # (node is still the object-owner; @desc didn't transfer ownership). This is
    # the assertion that is RED against the latest-signer oracle and GREEN once
    # node-ownership is judged by the meta child's GENESIS signer + zone.
    assert :ok = Verbs.dispatch(Parser.parse("spin orrery"), visitor_ctx(store, room, "boris"))
    assert spun_by(store, orrery) == "boris"
  end
end
