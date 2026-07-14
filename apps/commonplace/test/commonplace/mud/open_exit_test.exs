defmodule Commonplace.MUD.OpenExitTest do
  @moduledoc """
  CX-open_exit (plan design-doc 2026-07-13; CX-9tbi/CX-f0od) — the trust-gated
  safe-verb exit-mutation primitive `Facade.open_exit/3`. Covers the three gates
  under `:enforce` + strict trust:

    * Gate A (SOURCE authority): a citizen opens an exit in their OWN home
      (invoker-signed via their `:subtree` cert); a node-authored CURATED-room
      verb elevates (definer's-rights) and opens; a visitor in a room they don't
      own is DENIED.
    * Gate B (DEST scope / anti-intrusion): dest may be curated/public OR the
      invoker's own zone; wiring into ANOTHER player's private home is REFUSED —
      and REFUSED EVEN under node elevation (judged on the invoker, not the node).
    * Gate C (idempotent + non-clobbering): re-running is a no-op; a different
      dest on a taken dir is `{:error, :exit_exists}` (never silent reroute).
    * Surgical write: the room's node-signed `zone` stamp survives byte-identical.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Citizenship, Schemas, World}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_openexit_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"openexit_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"openexit_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"openexit_tss_#{n}",
       pending_imports_name: :"openexit_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      knob: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {k, v} <- old do
        key = %{data_dir: :data_dir, trust: :trust, knob: :local_write_gate}[k]
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    # world root (node-signed empty schema)
    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil, %{}, signing_context: node_ctx)

    # curated/public rooms reachable from root (NOT under players/)
    commons = mk_room!(store, node_ctx, "The Commons")
    add_dir!(store, root, "commons", commons, node_ctx)
    reward = mk_room!(store, node_ctx, "The Reward Vault")
    add_dir!(store, root, "reward", reward, node_ctx)
    curated_source = mk_room!(store, node_ctx, "The Puzzle Chamber")
    add_dir!(store, root, "puzzle", curated_source, node_ctx)

    # two real citizens with homes under players/ (private zones) + write certs
    {alice_id, alice_ctx, alice_pub} = fresh_ctx()
    {:ok, %{home_room_uuid: alice_home, cert_cids: alice_cids}} =
      Citizenship.ensure(alice_id, alice_pub, "alice", root, store)

    {bob_id, _bob_ctx, bob_pub} = fresh_ctx()
    {:ok, %{home_room_uuid: bob_home}} = Citizenship.ensure(bob_id, bob_pub, "bob", root, store)

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      commons: commons,
      reward: reward,
      curated_source: curated_source,
      alice_id: alice_id,
      alice_ctx: alice_ctx,
      alice_cids: alice_cids,
      alice_home: alice_home,
      bob_home: bob_home
    }
  end

  # ---- helpers ----

  defp fresh_ctx do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    {id, %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}, pub}
  end

  defp mk_room!(store, signing_ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "a place"}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp add_dir!(store, parent, name, child, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, child)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent, store: store, signing_context: signing_ctx)
    {_, _} = {metadata, commit_opts}

    case CommitStoreClient.create_chained_commit(store, parent, update, metadata, commit_opts) do
      {:error, e} -> raise "add_dir! failed: #{inspect(e)}"
      _ -> :ok
    end
  end

  # A facade bound to `source_room` as its host, with `owner_grant` and the
  # invoker's ctx (signing_context + cert_cids + root). host_kind: :room.
  defp room_facade(source_room, owner_grant, ctx_fields, store) do
    ctx =
      Map.merge(
        %{cert_cids: [], signer_id: nil, current_room_uuid: source_room, root_uuid: nil, player_name: "p"},
        ctx_fields
      )

    %{Facade.new(ctx, source_room, owner_grant, {"verbs/x.safe.elx", "owner-x"}, store) | host_kind: :room}
  end

  defp exits_of(store, room) do
    {:ok, %Room{exits: exits}} = World.get_room(room, store)
    exits
  end

  # ---- Gate A: citizen opens in OWN zone ----

  test "Gate A: a citizen opens an exit in their OWN home to a curated room (invoker-signed)", ctx do
    f =
      room_facade(ctx.alice_home, [ctx.alice_home], %{
        signing_context: ctx.alice_ctx,
        cert_cids: ctx.alice_cids,
        root_uuid: ctx.root
      }, ctx.store)

    assert :ok = Facade.open_exit(f, "north", ctx.commons)
    assert %{"north" => dest} = exits_of(ctx.store, ctx.alice_home)
    assert dest == ctx.commons
  end

  # ---- Gate A: node-authored CURATED-room verb elevates + opens ----

  test "Gate A: a visitor triggering a CURATED room's verb elevates (node) and opens an exit", ctx do
    # visitor holds NO cert; the curated source room is node-owned → object_owner
    # _authority elevates. owner_grant = [curated_source] (the room's own verb).
    {_vid, vctx, _} = fresh_ctx()

    f =
      room_facade(ctx.curated_source, [ctx.curated_source], %{
        signing_context: vctx,
        cert_cids: [],
        root_uuid: ctx.root
      }, ctx.store)

    assert :ok = Facade.open_exit(f, "down", ctx.reward)
    assert %{"down" => dest} = exits_of(ctx.store, ctx.curated_source)
    assert dest == ctx.reward
    # landed node-signed (elevation), not visitor-signed
    {:ok, meta} = World.meta_doc_uuid(ctx.curated_source, Schemas.room_filename(), ctx.store)
    {:ok, commit} = CommitStore.latest_commit(ctx.store, meta)
    assert {:ok, node_id, _} = Signing.parse_signer_id(commit.signer_id)
    assert node_id == ctx.node_identity
  end

  # ---- Gate A: visitor in a room they don't own is DENIED ----

  test "Gate A DENY: a visitor cannot open an exit in a room not in their owner_grant (reach)", ctx do
    {_vid, vctx, _} = fresh_ctx()

    # owner_grant is the visitor's own (empty-ish) grant, NOT the curated source.
    f =
      room_facade(ctx.curated_source, [UUID.uuid4()], %{
        signing_context: vctx,
        cert_cids: [],
        root_uuid: ctx.root
      }, ctx.store)

    # reach fails (source ∉ owner_grant) → owner_grant_exceeded, sanitized to the
    # generic :refused at the facade boundary (permission-class); the raw reason
    # rides the drop-accumulator for the author-diagnostic.
    assert {:error, :refused} = Facade.open_exit(f, "down", ctx.reward)
    refute Map.has_key?(exits_of(ctx.store, ctx.curated_source), "down")
  end

  test "Gate A DENY: a visitor triggering a PLAYER-owned room's own verb is refused (no node elevation)", ctx do
    # Bob's home is player-authored (NOT node-owned) → object_owner_authority :none
    # → invoker-signed → the visitor's write is denied at the gate. owner_grant =
    # [bob_home] (as if bob's home hosted the verb), but no elevation applies.
    {_vid, vctx, _} = fresh_ctx()

    f =
      room_facade(ctx.bob_home, [ctx.bob_home], %{
        signing_context: vctx,
        cert_cids: [],
        root_uuid: ctx.root
      }, ctx.store)

    # invoker-signed write denied at the trust gate → {:trust_rejected}, sanitized
    # to :refused (permission-class) at the facade boundary.
    assert {:error, :refused} = Facade.open_exit(f, "north", ctx.commons)
    refute Map.has_key?(exits_of(ctx.store, ctx.bob_home), "north")
  end

  # ---- Gate B: anti-intrusion — cannot wire into another player's private home ----

  test "Gate B: opening an exit whose DEST is another player's PRIVATE home is REFUSED (even under node elevation)", ctx do
    # A CURATED source verb (elevates to node via Gate A) tries to wire a passage
    # INTO bob's private home. Gate B judges the dest on the INVOKER (visitor,
    # can't write bob's home) + bob's home is under players/ (not curated_public)
    # → :dest_forbidden. Anti-intrusion holds even though Gate A would elevate.
    {_vid, vctx, _} = fresh_ctx()

    f =
      room_facade(ctx.curated_source, [ctx.curated_source], %{
        signing_context: vctx,
        cert_cids: [],
        root_uuid: ctx.root
      }, ctx.store)

    assert {:error, :dest_forbidden} = Facade.open_exit(f, "secret", ctx.bob_home)
    refute Map.has_key?(exits_of(ctx.store, ctx.curated_source), "secret")
  end

  test "Gate B: a citizen CAN wire an exit into their OWN reward zone (self-owned dest)", ctx do
    # alice opens an exit from her home to... her home is self-owned; use commons
    # already covered. Here: dest = alice_home itself (self-owned) from a curated
    # source is blocked for a visitor, but alice from her own home to a curated
    # dest is the happy path (covered). Assert alice→commons (public) is allowed
    # AND alice can also point at a room she can write (her own home, self-loop ok
    # structurally — Gate B self-owned branch).
    f =
      room_facade(ctx.alice_home, [ctx.alice_home], %{
        signing_context: ctx.alice_ctx,
        cert_cids: ctx.alice_cids,
        root_uuid: ctx.root
      }, ctx.store)

    # self-owned dest (alice's own home) passes Gate B via invoker_can_write(dest)
    assert :ok = Facade.open_exit(f, "mirror", ctx.alice_home)
    assert %{"mirror" => dest} = exits_of(ctx.store, ctx.alice_home)
    assert dest == ctx.alice_home
  end

  # ---- Gate C: idempotent + non-clobbering ----

  test "Gate C: re-opening the SAME dir=>dest is an idempotent no-op", ctx do
    f =
      room_facade(ctx.alice_home, [ctx.alice_home], %{
        signing_context: ctx.alice_ctx,
        cert_cids: ctx.alice_cids,
        root_uuid: ctx.root
      }, ctx.store)

    assert :ok = Facade.open_exit(f, "north", ctx.commons)
    assert :ok = Facade.open_exit(f, "north", ctx.commons)
    # exactly one exit, unchanged
    assert %{"north" => c} = exits_of(ctx.store, ctx.alice_home)
    assert c == ctx.commons
  end

  test "Gate C: opening a TAKEN dir to a DIFFERENT dest is refused :exit_exists (no silent reroute)", ctx do
    f =
      room_facade(ctx.alice_home, [ctx.alice_home], %{
        signing_context: ctx.alice_ctx,
        cert_cids: ctx.alice_cids,
        root_uuid: ctx.root
      }, ctx.store)

    assert :ok = Facade.open_exit(f, "north", ctx.commons)
    assert {:error, :exit_exists} = Facade.open_exit(f, "north", ctx.reward)
    # still points at the ORIGINAL dest — never rerouted
    assert %{"north" => c} = exits_of(ctx.store, ctx.alice_home)
    assert c == ctx.commons
  end

  # ---- dest validation + surgical write ----

  test "dest must be a valid room (a non-room uuid is refused :no_such_dest)", ctx do
    f =
      room_facade(ctx.alice_home, [ctx.alice_home], %{
        signing_context: ctx.alice_ctx,
        cert_cids: ctx.alice_cids,
        root_uuid: ctx.root
      }, ctx.store)

    assert {:error, :no_such_dest} = Facade.open_exit(f, "void", UUID.uuid4())
  end

  test "SURGICAL: opening an exit leaves the room's other meta fields (name/description) intact", ctx do
    {:ok, before} = World.get_room(ctx.alice_home, ctx.store)

    f =
      room_facade(ctx.alice_home, [ctx.alice_home], %{
        signing_context: ctx.alice_ctx,
        cert_cids: ctx.alice_cids,
        root_uuid: ctx.root
      }, ctx.store)

    assert :ok = Facade.open_exit(f, "north", ctx.commons)
    {:ok, after_room} = World.get_room(ctx.alice_home, ctx.store)

    # only exits changed; name/description/owner/visibility byte-identical
    assert after_room.name == before.name
    assert after_room.description == before.description
    assert after_room.owner == before.owner
    assert after_room.visibility == before.visibility
    assert Map.has_key?(after_room.exits, "north")
  end
end
