defmodule Commonplace.MUD.ChildMutationTest do
  @moduledoc """
  CX-4u03 / A1c — the sole zone-stamp writer. Proves plan #7262's escalation
  bounds by construction: self-root is node-only, a zoned child INHERITS its
  parent's zone (the caller never supplies one), a player builds under their home
  via their {:subtree} cert (split authority: node-signed stamp + player-signed
  entry-add), and a player CANNOT build outside their zone (the carve rejects the
  entry-add). Runs under `local_write_gate: :enforce`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MUD.{ChildMutation, Schemas}
  alias Commonplace.Trust
  alias Commonplace.Trust.Capability
  alias Commonplace.Crypto.{Signing, SigningContext, NodeIdentity}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_childmut_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"childmut_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"childmut_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"childmut_tss_#{n}",
       pending_imports_name: :"childmut_pi_#{n}"}
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

        if is_nil(v),
          do: Application.delete_env(:commonplace, key),
          else: Application.put_env(:commonplace, key, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # a node-owned parent dir (like players/) to hang zone roots off of
    {:ok, players} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    %{store: store, node_ctx: node_ctx, players: players}
  end

  defp room_json(name), do: Schemas.encode_room(%Schemas.Room{name: name, description: "a room"})

  defp player_subtree_cert(store, node_ctx, root) do
    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    ctx = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}

    {:ok, cap} =
      Capability.issue(
        node_ctx,
        {pid, pub},
        %{verbs: [:write], scope: {:subtree, root}, caveats: %{}},
        nil,
        store: store
      )

    :ok = CommitStoreClient.store_capability(store, cap)
    %{id: pid, ctx: ctx, cid: cap.id, creds: [signing_context: ctx, cert_cids: [cap.id]]}
  end

  defp entry?(dir, name, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir, store)
    match?({:ok, _}, Schema.get_entry(schema, name))
  end

  test "create_zone_root SELF-ROOTS: child.zone == its own uuid", %{
    store: store,
    players: players
  } do
    assert {:ok, home} =
             ChildMutation.create_zone_root(
               players,
               "alice",
               Schemas.room_filename(),
               room_json("Alice's Home"),
               store
             )

    assert Trust.doc_zone(home, store) == home
    assert entry?(players, "alice", store)
  end

  test "create_zoned_child INHERITS the parent's zone", %{store: store, players: players} do
    {:ok, home} =
      ChildMutation.create_zone_root(
        players,
        "bob",
        Schemas.room_filename(),
        room_json("Bob's Home"),
        store
      )

    # node builds a child under the home (node entry-add for this test)
    {:ok, node_ctx} = NodeIdentity.signing_context()

    assert {:ok, study} =
             ChildMutation.create_zoned_child(
               home,
               "study",
               Schemas.room_filename(),
               room_json("Study"),
               store,
               signing_context: node_ctx
             )

    assert Trust.doc_zone(study, store) == home
    assert entry?(home, "study", store)
  end

  test "un-zoned parent → un-stamped child (fail-closed-safe, no forged zone)", %{
    store: store,
    players: players
  } do
    # `players` itself is a bare node dir with no zone → a child under it inherits nil
    {:ok, node_ctx} = NodeIdentity.signing_context()

    assert {:ok, child} =
             ChildMutation.create_zoned_child(
               players,
               "loose",
               Schemas.room_filename(),
               room_json("Loose"),
               store,
               signing_context: node_ctx
             )

    assert Trust.doc_zone(child, store) == nil
  end

  test "PLAYER builds under their home via their {:subtree} cert (split authority)", %{
    store: store,
    node_ctx: node_ctx,
    players: players
  } do
    {:ok, home} =
      ChildMutation.create_zone_root(
        players,
        "carol",
        Schemas.room_filename(),
        room_json("Carol's Home"),
        store
      )

    p = player_subtree_cert(store, node_ctx, home)

    # the entry-add is PLAYER-signed (authorized by {:subtree, home} since
    # home.zone == home); the child mint + zone stamp are node-signed.
    assert {:ok, study} =
             ChildMutation.create_zoned_child(
               home,
               "study",
               Schemas.room_filename(),
               room_json("Study"),
               store,
               p.creds
             )

    assert entry?(home, "study", store)
    # the child inherited the home zone (node-stamped) — the player now owns it
    # via the SAME {:subtree, home} cert
    assert Trust.doc_zone(study, store) == home
  end

  test "a PLAYER cannot build OUTSIDE their zone (the entry-add is carve-rejected)", %{
    store: store,
    node_ctx: node_ctx,
    players: players
  } do
    {:ok, home1} =
      ChildMutation.create_zone_root(
        players,
        "dave",
        Schemas.room_filename(),
        room_json("Dave's Home"),
        store
      )

    {:ok, home2} =
      ChildMutation.create_zone_root(
        players,
        "erin",
        Schemas.room_filename(),
        room_json("Erin's Home"),
        store
      )

    # dave holds {:subtree, home1} only
    dave = player_subtree_cert(store, node_ctx, home1)

    # dave tries to build under erin's home2 → the player-signed entry-add to
    # home2 (zone=home2) is not covered by dave's {:subtree, home1} cert → the
    # carve rejects it → link fails.
    assert {:error, _} =
             ChildMutation.create_zoned_child(
               home2,
               "sneak",
               Schemas.room_filename(),
               room_json("Sneak"),
               store,
               dave.creds
             )

    refute entry?(home2, "sneak", store)
  end
end
