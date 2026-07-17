defmodule Commonplace.MUD.Cl65ExitWriteZoneTest do
  @moduledoc """
  CX-cl65 — @dig/@link denied in a player's OWN fresh home.

  Root cause pin: the exit-write (`Verbs.update_room_exit`, shared by @dig and
  @link) round-trips the room meta through the typed `%Schemas.Room{}` struct,
  which has NO `zone` field — so the re-encoded JSON DROPS the node-signed `zone`
  stamp. The subtree write-carve reads that as a protected-field delta
  (`zone: home → absent`) and DENIES the otherwise-authorized player write.
  `@desc`/`@name` go through `World.set_meta` (a surgical `Map.put` on the raw
  JSON) which preserves `zone`, which is exactly why they succeed while @dig/@link
  fail. This test pins both halves: round-trip → denied, surgical → allowed.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.MUD.{Citizenship, Schemas, World}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cl65_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"cl65_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cl65_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cl65_tss_#{n}",
       pending_imports_name: :"cl65_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore(:data_dir, old_data_dir)
      restore(:trust, old_trust)
      restore(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(Schema.new_schema()), nil, %{}, signing_context: node_ctx)

    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    citizen = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}
    {:ok, %{cert_cids: cids, home_room_uuid: home}} = Citizenship.ensure(pid, pub, "builder", root, store)

    %{store: store, root: root, home: home, citizen: citizen, cids: cids}
  end

  defp restore(:data_dir, nil), do: Application.put_env(:commonplace, :data_dir, "tmp/test_data")
  defp restore(k, nil), do: Application.delete_env(:commonplace, k)
  defp restore(k, v), do: Application.put_env(:commonplace, k, v)

  test "the home room meta carries a zone stamp == home", %{store: store, home: home} do
    {:ok, map} = World.get_meta_map(home, Schemas.room_filename(), store)
    assert Map.get(map, "zone") == home
  end

  test "REPRO: %Room{} round-trip drops zone → carve DENIES the exit-write", %{store: store, home: home, citizen: citizen, cids: cids} do
    {:ok, sch} = Schemas.load_dir_schema(home, store)
    {:ok, entry} = Schema.get_entry(sch, Schemas.room_filename())
    {:ok, room} = World.get_room(home, store)

    dropped = Schemas.encode_room(%{room | exits: Map.put(room.exits, "north", UUID.uuid4())})
    refute Map.has_key?(Jason.decode!(dropped), "zone")

    opts = [store: store, signing_context: citizen, cert_cids: cids, signer_id: nil]
    assert {:error, {:trust_rejected, _}} = Schemas.write_meta_doc(entry.node_id, dropped, store, opts)
  end

  test "END-TO-END: a citizen @digs a room in their OWN home under :enforce (the M2 headline)", %{store: store, root: root, home: home, citizen: citizen, cids: cids} do
    # The player stands IN their home (current_room = home) and runs the REAL
    # @dig verb through the real dispatcher, with their real issued cert — the
    # exact black-box path fable's gate exercised. This is the regression that
    # was missing: the prior @dig e2e tests run under the permissive gate.
    ctx = %{
      store: store,
      player_name: "builder",
      root_uuid: root,
      current_room_uuid: home,
      inventory_uuid: nil,
      signing_context: citizen,
      cert_cids: cids,
      signer_id: nil
    }

    cmd = Commonplace.MUD.Parser.parse("@dig north Study")
    assert {:reply, msg} = Commonplace.MUD.Verbs.dispatch(cmd, ctx)
    assert msg =~ "carve out"

    # The home room now has a north exit AND still carries its zone stamp.
    {:ok, after_map} = World.get_meta_map(home, Schemas.room_filename(), store)
    assert Map.get(after_map, "exits") |> Map.has_key?("north")
    assert Map.get(after_map, "zone") == home
  end

  test "FIX: surgical merge preserves zone → carve ALLOWS the exit-write", %{store: store, home: home, citizen: citizen, cids: cids} do
    {:ok, sch} = Schemas.load_dir_schema(home, store)
    {:ok, entry} = Schema.get_entry(sch, Schemas.room_filename())
    {:ok, map} = World.get_meta_map(home, Schemas.room_filename(), store)

    surgical =
      map
      |> Map.put("exits", Map.put(Map.get(map, "exits", %{}), "north", UUID.uuid4()))
      |> Jason.encode!()

    assert Map.get(Jason.decode!(surgical), "zone") == home

    opts = [store: store, signing_context: citizen, cert_cids: cids, signer_id: nil]
    assert :ok = Schemas.write_meta_doc(entry.node_id, surgical, store, opts)

    {:ok, doc} = DocBuilder.reconstruct_doc(store, entry.node_id)
    reread = Jason.decode!(ContentType.get_content(doc))
    assert Map.get(reread, "exits") |> Map.has_key?("north")
    assert Map.get(reread, "zone") == home
  end
end
