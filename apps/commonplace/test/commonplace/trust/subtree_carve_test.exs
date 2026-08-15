defmodule Commonplace.Trust.SubtreeCarveTest do
  @moduledoc """
  CX-4u03 / A1 (subtree-scope, the trust-core) — under `local_write_gate:
  :enforce`, a `{:subtree, R}` capability authorizes a player-signed write to a
  doc IFF the doc's CARRIED, node-signed zone-stamp == R (membership, read from
  the target's own governing meta — never a live tree-walk), the write does NOT
  tamper the protected `zone` field, and a :write-without-:execute subtree cert
  isn't authoring a code doc. Fails CLOSED on an absent/unreadable stamp.

  These exercise the REAL write-gate (`Schemas.write_meta_doc` → `Trust.grants?`
  → `subtree_carve_ok?`), mirroring the presence-signing carve tests.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Trust
  alias Commonplace.Trust.{Capability, CodeDocHeuristic, Read, VerifyChain}
  alias Commonplace.Crypto.{Signing, SigningContext, NodeIdentity}
  alias Commonplace.Store.CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_subtree_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"subtree_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"subtree_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"subtree_tss_#{n}",
       pending_imports_name: :"subtree_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      gate: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {k, v} <- old do
        key = %{data_dir: :data_dir, trust: :trust, gate: :local_write_gate}[k]
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # A node-owned room dir + its __room.json meta child (node-signed, unstamped
    # as minted — create_dir_with_meta does not stamp; that is A1c's chokepoint).
    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Schemas.Room{name: "Room", description: "a room"}),
        store,
        signing_context: node_ctx
      )

    %{store: store, node_ctx: node_ctx, room: room}
  end

  # Node-signs a `zone` stamp onto the room's meta child (stands in for A1c's
  # chokepoint, which will mint it by-construction).
  defp stamp_zone(room, zone, store, node_ctx) do
    :ok = World.set_meta(room, Schemas.room_filename(), "zone", zone, store, signing_context: node_ctx)
  end

  # A fresh player identity + a node-issued {:subtree, root} [:write] cert.
  defp player_with_subtree_cert(store, node_ctx, root) do
    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    ctx = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}

    {:ok, cap} =
      Capability.issue(node_ctx, {pid, pub}, %{verbs: [:write], scope: {:subtree, root}, caveats: %{}}, nil, store: store)

    :ok = CommitStoreClient.store_capability(store, cap)
    %{id: pid, pub: pub, ctx: ctx, cid: cap.id, creds: [signing_context: ctx, cert_cids: [cap.id]]}
  end

  defp fresh_reader do
    {pub, _priv} = Signing.generate_keypair()
    %{id: UUID.uuid4(), pub: pub}
  end

  defp meta_field(room, key, store) do
    {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, meta_uuid(room, store))
    Commonplace.Document.ContentType.get_content(doc) |> Jason.decode!() |> Map.get(key)
  end

  defp meta_uuid(room, store) do
    {:ok, uuid} = World.meta_doc_uuid(room, Schemas.room_filename(), store)
    uuid
  end

  test "member write LANDS: a {:subtree,R} cert writes game content of a doc stamped R", %{store: store, node_ctx: node_ctx, room: room} do
    zone = UUID.uuid4()
    stamp_zone(room, zone, store, node_ctx)
    p = player_with_subtree_cert(store, node_ctx, zone)

    assert :ok = World.set_meta(room, Schemas.room_filename(), "description", "player edit", store, p.creds)
    assert meta_field(room, "description", store) == "player edit"
    # the stamp is untouched
    assert meta_field(room, "zone", store) == zone
  end

  test "MISMATCH rejected: a {:subtree,OTHER} cert cannot write a doc stamped R", %{store: store, node_ctx: node_ctx, room: room} do
    zone = UUID.uuid4()
    stamp_zone(room, zone, store, node_ctx)
    p = player_with_subtree_cert(store, node_ctx, UUID.uuid4())

    assert {:error, _} = World.set_meta(room, Schemas.room_filename(), "description", "nope", store, p.creds)
    refute meta_field(room, "description", store) == "nope"
  end

  test "UNSTAMPED rejected (fail-closed): a subtree cert cannot write a doc with no zone", %{store: store, node_ctx: node_ctx, room: room} do
    # never stamp the room
    p = player_with_subtree_cert(store, node_ctx, UUID.uuid4())
    assert {:error, _} = World.set_meta(room, Schemas.room_filename(), "description", "nope", store, p.creds)
  end

  test "STAMP PROTECTION: a subtree cert cannot rewrite the protected zone field", %{store: store, node_ctx: node_ctx, room: room} do
    zone = UUID.uuid4()
    stamp_zone(room, zone, store, node_ctx)
    p = player_with_subtree_cert(store, node_ctx, zone)

    # attempt to move this doc into a different zone by rewriting its stamp
    assert {:error, _} = World.set_meta(room, Schemas.room_filename(), "zone", UUID.uuid4(), store, p.creds)
    assert meta_field(room, "zone", store) == zone
  end

  test "commitless elevation mirror: writer_authorized? tracks subtree membership", %{store: store, node_ctx: node_ctx, room: room} do
    zone = UUID.uuid4()
    stamp_zone(room, zone, store, node_ctx)
    member = player_with_subtree_cert(store, node_ctx, zone)
    stranger = player_with_subtree_cert(store, node_ctx, UUID.uuid4())

    # the REAL cfg auto-pins the NodeIdentity (Trust.config/0) so the node-rooted
    # subtree cap's chain verifies against the node anchor
    cfg = Trust.config()
    target = meta_uuid(room, store)

    assert Trust.writer_authorized?(member.id, member.pub, [member.cid], target, cfg, store)
    refute Trust.writer_authorized?(stranger.id, stranger.pub, [stranger.cid], target, cfg, store)
  end

  test "subtree read cert authorizes a reader inside its carried zone", %{
    store: store,
    node_ctx: node_ctx,
    room: room
  } do
    zone = UUID.uuid4()
    stamp_zone(room, zone, store, node_ctx)
    reader = fresh_reader()

    assert {:ok, cap} =
             Read.grant(node_ctx, {:subtree, zone}, {reader.id, reader.pub}, store: store)

    assert {:ok, %{verbs: verbs, scope: {:subtree, ^zone}}} =
             VerifyChain.verify_chain(cap.id, MapSet.new([node_ctx.public_key]), store)

    assert :read in verbs
    reader_id = reader.id
    assert {^reader_id, audience_pub} = cap.audience
    assert reader.pub == audience_pub

    cfg = %{
      accept_unsigned: false,
      trusted_identities: %{node_ctx.identity_uuid => Signing.encode_key(node_ctx.public_key)}
    }

    target = meta_uuid(room, store)
    assert Trust.reader_authorized?(reader.id, reader.pub, [cap.id], target, cfg, store)

    {:ok, outside_room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Schemas.Room{name: "Outside", description: "another room"}),
        store,
        signing_context: node_ctx
      )

    stamp_zone(outside_room, UUID.uuid4(), store, node_ctx)
    outside_target = meta_uuid(outside_room, store)

    refute Trust.reader_authorized?(
             reader.id,
             reader.pub,
             [cap.id],
             outside_target,
             cfg,
             store
           )
  end

  test "existing doc-scoped read grants remain exact", %{
    store: store,
    node_ctx: node_ctx,
    room: room
  } do
    reader = fresh_reader()
    target = meta_uuid(room, store)

    assert {:ok, cap} =
             Read.grant(node_ctx, target, {reader.id, reader.pub}, store: store)

    assert {:ok, %{verbs: verbs, scope: {:docs, [^target]}}} =
             VerifyChain.verify_chain(cap.id, MapSet.new([node_ctx.public_key]), store)

    assert :read in verbs
    reader_id = reader.id
    assert {^reader_id, audience_pub} = cap.audience
    assert reader.pub == audience_pub

    cfg = %{
      accept_unsigned: false,
      trusted_identities: %{
        node_ctx.identity_uuid => Signing.encode_key(node_ctx.public_key)
      }
    }

    assert Trust.reader_authorized?(reader.id, reader.pub, [cap.id], target, cfg, store)

    refute Trust.reader_authorized?(
             reader.id,
             reader.pub,
             [cap.id],
             UUID.uuid4(),
             cfg,
             store
           )
  end

  test "shared code-doc classifier (the write⊥execute belt predicate)", _ctx do
    assert CodeDocHeuristic.code_content?("defmodule Foo.Bar do\n  def x, do: 1\nend")
    refute CodeDocHeuristic.code_content?(~s({"kind":"room","name":"Hall","zone":"z1"}))
    refute CodeDocHeuristic.code_content?(nil)
  end
end
