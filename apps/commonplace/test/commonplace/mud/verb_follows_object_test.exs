defmodule Commonplace.MUD.VerbFollowsObjectTest do
  @moduledoc """
  CX-eqdr (a) — the free-follow LOCK-IN (plan #7729, design
  `/home/jes/commonplace-plan/docs/plans/2026-07-12-cx-eqdr-verbs-follow-objects-design.md`
  §5.1). A FORWARD-GUARD, not a mechanic.

  "Verbs follow objects" is ALREADY TRUE at dispatch for every object that
  exists today (all node-authored/curated) and needs nothing built. Why:
  `Move.move` rewrites ONLY the two PARENT dir schemas (add-to-dest,
  remove-from-source) — it NEVER rewrites the moved node's own doc. So the moved
  object's own zone-stamp is INVARIANT under a move, and a node-authored object
  verb (a node signer is "authorized regardless of host", trust.ex:288-292)
  keeps dispatching after the object is carried into a different zone, for free.

  This test PINS that invariant so a future move-path change can't silently break
  it. If someone ever "helpfully" wires a re-stamp of the moved node into the
  move/take path (the thing plan #7729 says NOT to do — it would break
  free-dispatch AND violate the CX-55o3 possession ≠ write-authority split), the
  two structural assertions below trip:

    1. `Trust.doc_zone(object)` is byte-identical before/after the move, AND the
       object dir's OWN `latest_commit.id` (content-address) is unchanged — the
       crispest form of "Move never rewrote the moved node's own doc".
    2. A node-authored verb authored in the origin zone still DISPATCHES + RUNS
       from the destination zone (the "verbs follow objects" win).

  Setup mirrors `Commonplace.MUD.VerbTakeBrickTest` (enforce + Store.Supervisor
  trio + Bursar + node identity). Rooms are real, DISTINCT zone roots
  (`ChildMutation.create_zone_root`); the object is a genuinely zoned, node-owned
  child (`ChildMutation.create_zoned_child`, zone inherited from the origin room)
  so a hypothetical re-stamp-on-move would flip its stamp from origin→dest and
  fail assertion (1) loudly.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Green.Bursar
  alias Commonplace.MUD.{ChildMutation, Move, Parser, Schemas, VerbSource, Verbs, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Trust

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_vfollow_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"vfollow_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"vfollow_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"vfollow_tss_#{n}",
       pending_imports_name: :"vfollow_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
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

    # A bare node-signed dir to hang the two zone-root rooms under
    # (create_zone_root links each room into a parent it signs node-side).
    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    %{store: store, node_ctx: node_ctx, node_identity: node_identity, root: root}
  end

  defp zone_room!(store, root, name) do
    {:ok, uuid} =
      ChildMutation.create_zone_root(
        root,
        "room-#{name}",
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "the #{name} room"}),
        store
      )

    uuid
  end

  defp node_object_in!(store, room, node_ctx, name) do
    {:ok, uuid} =
      ChildMutation.create_zoned_child(
        room,
        "#{name}.obj",
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: node_ctx
      )

    uuid
  end

  defp save_node_verb!(store, host, node_ctx, verb, key) do
    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "#{key}", "yes")|

    :ok =
      VerbSource.save_safe_verb(host, verb, body, [host], store,
        signing_context: node_ctx,
        cert_cids: [],
        signer_id: nil
      )
  end

  defp player_ctx(store, root, room) do
    %{
      player_name: "wanderer",
      player_uuid: UUID.uuid4(),
      player_dir_uuid: UUID.uuid4(),
      inventory_uuid: UUID.uuid4(),
      current_room_uuid: room,
      presence_filename: "wanderer.usr",
      root_uuid: root,
      store: store,
      signing_context: nil,
      signer_id: nil,
      cert_cids: []
    }
  end

  defp state_key(store, obj, key) do
    {:ok, schema} = Schemas.load_dir_schema(obj, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.object_filename())
    {:ok, doc} = DocBuilder.reconstruct_doc(store, entry.node_id)
    get_in(Jason.decode!(ContentType.get_content(doc)), ["state", key])
  end

  test "a node-authored object verb still dispatches after the object moves across zones — and the move never rewrites the object's own doc",
       %{store: store, node_ctx: node_ctx, root: root} do
    room_a = zone_room!(store, root, "Origin")
    room_b = zone_room!(store, root, "Beyond")

    # Genuinely DISTINCT zones (each room is its own zone root).
    assert Trust.doc_zone(room_a, store) == room_a
    assert Trust.doc_zone(room_b, store) == room_b
    refute room_a == room_b

    # A node-owned, zoned object born in zone A, carrying its origin stamp.
    idol = node_object_in!(store, room_a, node_ctx, "idol")
    assert Trust.doc_zone(idol, store) == room_a

    # Two node-authored verbs: `bless` fired NOW (baseline), `curse` fired only
    # AFTER the move (its state key can't exist pre-move, so its presence proves
    # the verb ran in zone B).
    save_node_verb!(store, idol, node_ctx, "bless", "blessed")
    save_node_verb!(store, idol, node_ctx, "curse", "cursed")

    # Baseline: the verb dispatches + runs in the origin zone.
    assert :ok = Verbs.dispatch(Parser.parse("bless idol"), player_ctx(store, root, room_a))
    assert state_key(store, idol, "blessed") == "yes"
    refute state_key(store, idol, "cursed")

    # Capture the invariant witnesses immediately before the move: the object's
    # own stamp and its own latest commit (content-addressed id).
    zone_before = Trust.doc_zone(idol, store)
    {:ok, commit_before} = CommitStoreClient.latest_commit(store, idol)

    # Carry the object across zones (A → B). Node-signed writes to the two zone
    # roots; the object's OWN doc is not in the write set.
    assert :ok =
             Move.move(idol, "idol.obj", room_a, room_b,
               store: store,
               bursar: Bursar,
               signing_context: node_ctx
             )

    # It really moved.
    assert Enum.any?(World.list_objects_in(room_b, store), &(&1.node_id == idol))
    refute Enum.any?(World.list_objects_in(room_a, store), &(&1.node_id == idol))

    # ASSERTION 1 — the load-bearing invariant: the moved node's own doc is
    # byte-identical. Its zone-stamp did NOT flip to zone B, and its own latest
    # commit id is unchanged (Move rewrote only the parent room schemas).
    {:ok, commit_after} = CommitStoreClient.latest_commit(store, idol)
    assert Trust.doc_zone(idol, store) == zone_before
    assert Trust.doc_zone(idol, store) == room_a
    assert commit_after.id == commit_before.id

    # ASSERTION 2 — verbs follow the object: the node-authored `curse`, authored
    # in zone A, dispatches + runs from zone B. `cursed` was absent pre-move, so
    # its presence proves the verb fired post-move in the new zone.
    assert :ok = Verbs.dispatch(Parser.parse("curse idol"), player_ctx(store, root, room_b))
    assert state_key(store, idol, "cursed") == "yes"
  end
end
