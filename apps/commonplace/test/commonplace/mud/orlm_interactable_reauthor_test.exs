defmodule Commonplace.MUD.OrlmInteractableReauthorTest do
  @moduledoc """
  CX-orlm — the Facade sibling of the CX-55o3 presence-oracle-fragility class,
  and its two-axis fix (plan #7739/#7743).

  `Facade.put_state` (an interactable's verb effect) elevates a non-owner
  visitor's write to the OBJECT-OWNER (node, for curated content) via
  `object_owner_authority/2`. The FRAGILE version gated on the meta child's
  LATEST-commit signer, so an authorized non-node meta write (`@desc`/`@name`, a
  co-curator) flipped the latest signer off the node → `:none` → the visitor's
  write ran invoker-signed → the enforce gate refused it → the interactable
  BRICKED for every visitor though still curated.

  THE FIX judges node-ownership on TWO axes, both failing toward UNDER-elevation:
    * AXIS 1 (authority gate, fail-CLOSED): the meta child's GENESIS signer is
      the node (frozen — `@desc` appends LATER commits but never rewrites
      genesis). The durable-record analogue of CX-55o3's possession token.
    * AXIS 2 (exclusion veto, fail-OPEN): the object is NOT positively in a
      player-owned zone (`Take.player_zone?`, the shared `players/` notion).
      Fail-OPEN on absence (nil zone) preserves the CX-gjpi contract (unzoned
      curated interactables elevate); AXIS 1 is the primary gate that excludes
      today's player objects (invoker genesis).

  PIN 1 — the reproduced brick, now GREEN: a curated (node-genesis) interactable
  stays visitor-usable after an authorized `@desc` re-chains its meta child
  latest-signer, because AXIS 1 reads the FROZEN genesis (still node).

  PIN 2 — ISOLATED AXIS 2 (plan's pin discipline, the CX-55o3 :available-fallback
  lesson): construct the adversarial shape AXIS 1 alone can't catch — a
  node-genesis meta child whose zone roots POSITIVELY under `players/` — and
  prove `object_owner_authority` returns `:none` there. AXIS 1 PASSES (genesis ==
  node), so `:none` is SOLELY AXIS 2, proving the veto fires.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Green.Bursar
  alias Commonplace.MUD.{ChildMutation, Parser, Schemas, Sections, SignedWrite, VerbSource, Verbs, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Trust
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

    # World root with a `players/` anchor (the node-controlled zone-ownership
    # boundary AXIS 2 reads).
    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    {:ok, players} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      players: players,
      root_ctx: root_ctx,
      editor_identity: editor_identity,
      editor_pub: editor_pub,
      editor_ctx: editor_ctx
    }
  end

  # ---- helpers ----

  defp add_dir_entry!(store, parent, name, child, sc) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, child)
    {metadata, commit_opts} = SignedWrite.opts_for(parent, store: store, signing_context: sc)
    _ = CommitStoreClient.create_chained_commit(store, parent, Encoding.encode_update(schema), metadata, commit_opts)
    :ok
  end

  # A curated (node-genesis meta) object, UNZONED — the shape of today's live
  # interactables (create_dir_with_meta node-signed).
  defp curated_object!(store, node_ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: node_ctx
      )

    uuid
  end

  # A NODE-genesis object ZONED under a player home (create_zoned_child inherits
  # the home's zone; the meta mint is node-signed). This is the adversarial
  # CX-8yzt-shape AXIS 2 must veto.
  defp node_object_in_zone!(store, zone_room, node_ctx, name) do
    {:ok, uuid} =
      ChildMutation.create_zoned_child(
        zone_room,
        "#{name}.obj",
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: node_ctx
      )

    uuid
  end

  defp save_node_spin!(store, host, node_ctx) do
    body =
      ~s|Commonplace.MUD.World.Facade.put_state(world, "spun_by", Commonplace.MUD.World.Facade.actor_name(world))|

    :ok = VerbSource.save_safe_verb(host, "spin", body, [host], store, signing_context: node_ctx)
  end

  defp visitor_ctx(store, root, room, name) do
    {pub, priv} = Signing.generate_keypair()
    id = "visitor-#{name}-#{:rand.uniform(1_000_000_000)}"

    %{
      player_name: name,
      player_uuid: UUID.uuid4(),
      player_dir_uuid: UUID.uuid4(),
      inventory_uuid: UUID.uuid4(),
      current_room_uuid: room,
      presence_filename: "#{name}.usr",
      root_uuid: root,
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
    parse(commit.signer_id)
  end

  # Mirror the fix's AXIS 1: the earliest AUTHORED commit's signer (commit_log is
  # latest-first; drop the synthetic genesis; take the last).
  defp meta_genesis_signer(store, obj) do
    {:ok, child} = World.meta_doc_uuid(obj, Schemas.object_filename(), store)

    CommitStoreClient.commit_log(store, child, limit: 10_000)
    |> Enum.reject(&match?(%{kind: :genesis}, Map.get(&1, :metadata)))
    |> List.last()
    |> then(fn %{signer_id: sid} -> parse(sid) end)
  end

  defp parse(signer_id) do
    case Signing.parse_signer_id(signer_id || "") do
      {:ok, id, _} -> id
      _ -> nil
    end
  end

  # ---- PIN 1: curated interactable survives an authorized @desc re-chain ----

  test "PIN 1: a curated interactable stays visitor-usable after an authorized @desc re-chains its meta child",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root,
         players: players,
         root_ctx: root_ctx,
         editor_identity: editor_identity,
         editor_pub: editor_pub,
         editor_ctx: editor_ctx
       } do
    # A curated room under root (NOT under players/), holding the interactable.
    {:ok, observatory} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "The Observatory", description: "a domed room"}),
        store,
        signing_context: node_ctx
      )

    add_dir_entry!(store, root, "observatory", observatory, node_ctx)
    _ = players

    orrery = curated_object!(store, node_ctx, "orrery")
    add_dir_entry!(store, observatory, "orrery.obj", orrery, node_ctx)
    save_node_spin!(store, orrery, node_ctx)

    # Baseline: the meta child starts node-owned on BOTH genesis and latest.
    assert meta_genesis_signer(store, orrery) == node_identity
    assert meta_latest_signer(store, orrery) == node_identity

    # Visitor A spins the curated object → elevated to node → lands.
    assert :ok = Verbs.dispatch(Parser.parse("spin orrery"), visitor_ctx(store, root, observatory, "ada"))
    assert spun_by(store, orrery) == "ada"

    # An AUTHORIZED non-node curator @descs the object (section cert over the
    # meta child) → the meta child's LATEST signer flips off the node...
    {:ok, child} = World.meta_doc_uuid(orrery, Schemas.object_filename(), store)

    {:ok, cap} =
      Sections.issue_section(root_ctx, {editor_identity, editor_pub}, [child], store: store, verbs: [:write])

    assert :ok =
             World.set_meta(orrery, Schemas.object_filename(), "description", "an ornate brass orrery",
               store,
               signing_context: editor_ctx,
               cert_cids: [cap.id]
             )

    # ...but GENESIS stays node (frozen) — the invariant AXIS 1 relies on.
    assert meta_latest_signer(store, orrery) == editor_identity
    assert meta_genesis_signer(store, orrery) == node_identity

    # Visitor B spins the SAME still-curated object → STILL elevates (AXIS 1
    # reads the frozen genesis, AXIS 2 no-ops on the nil zone) → lands.
    assert :ok = Verbs.dispatch(Parser.parse("spin orrery"), visitor_ctx(store, root, observatory, "boris"))
    assert spun_by(store, orrery) == "boris"
  end

  # ---- PIN 2: ISOLATED AXIS 2 — node-genesis object under players/ is vetoed --

  test "PIN 2 (ISOLATED AXIS 2): a node-genesis object zoned under players/ is NOT node-elevated for a visitor",
       %{store: store, node_ctx: node_ctx, node_identity: node_identity, root: root, players: players} do
    # A player home zone-root under players/ (node-signed genesis, zone == self).
    {:ok, home} =
      ChildMutation.create_zone_root(
        players,
        "alice-home",
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Alice's Home", description: "a cozy room"}),
        store
      )

    # A NODE-genesis object ZONED into that home (the adversarial CX-8yzt shape).
    trap = node_object_in_zone!(store, home, node_ctx, "trap")
    save_node_spin!(store, trap, node_ctx)

    # AXIS 1 PASSES: the meta genesis is the node (so :none below is SOLELY AXIS
    # 2 — the isolation). AXIS 2's condition holds: the zone roots under players/.
    assert meta_genesis_signer(store, trap) == node_identity
    assert Trust.doc_zone(trap, store) == home
    assert Commonplace.MUD.Take.player_zone?(home, root, store)

    # A visitor spins it → the elevation veto fires → the write is refused →
    # state never lands (no node-god-write onto a player-zoned object).
    assert :ok = Verbs.dispatch(Parser.parse("spin trap"), visitor_ctx(store, root, home, "mallory"))
    assert spun_by(store, trap) == nil
  end
end
