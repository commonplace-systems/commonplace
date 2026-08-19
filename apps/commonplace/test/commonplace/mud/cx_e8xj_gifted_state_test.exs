defmodule Commonplace.MUD.CxE8xjGiftedStateTest do
  @moduledoc """
  CX-e8xj — "a gift has to work": possession(token) → runtime-STATE authority.

  A citizen A `@creates` an object (node-GENESIS meta via ChildMutation, zoned
  under A's home = `players/`) and authors a `put_state` verb. A gives it to B
  (the possession TOKEN transfers). B invokes the verb: pre-fix, the verb's `say`
  fired but `put_state` was SILENTLY DROPPED — `Facade.object_owner_authority`
  resolved elevation by node-ownership ONLY (never the token), so B (neither
  author nor in-zone) hit the CX-orlm AXIS-2 zone veto → `:none` → the write ran
  invoker-signed → enforce refused it.

  THE FIX (plan #7773): a THIRD elevation axis — whoever HOLDS the object's
  possession token may drive its runtime STATE (`put_state`), while the verb CODE
  stays AUTHOR-signed (RCE unchanged) and the ZONE/curation stays subtree-cert.
  possession→state, authorship→code, zone→structure. The token branch lives in
  put_state's OWN authority ladder (`guarded_state_write`), so it is structurally
  unreachable by move/create/set_attr.

  SECURITY (the load-bearing catch): the token-elevation OVERRIDES the AXIS-2
  zone veto, so a holder's node-elevated write MUST be firewalled to `meta["state"]`
  only — the `zone` stamp + protected fields byte-identical — else B could
  re-stamp the object out of A's home to escape the very veto this overrides.

  Pins: (1) repro GREEN — holder's put_state persists; (2) ANTI-GRIEF — a
  non-holder non-author is refused; (3) SCOPE-ISOLATION — a holder cannot
  possession-elevate a non-state write (move_object); (4) FIREWALL — a holder's
  state-write cannot touch the zone stamp, and the `:state_only` firewall refuses
  a genuine non-state write.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{ChildMutation, Schemas, SignedWrite, VerbSource, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.MUD.World.Facade
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

    dir = Path.join(System.tmp_dir!(), "cp_e8xj_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"e8xj_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"e8xj_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"e8xj_tss_#{n}",
       pending_imports_name: :"e8xj_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v),
          do: Application.delete_env(:commonplace, key),
          else: Application.put_env(:commonplace, key, v)
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

    {:ok, bursar_pid} =
      Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)

    on_exit(fn ->
      if Process.alive?(bursar_pid),
        do:
          (try do
             GenServer.stop(bursar_pid)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    {:ok, players} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      players: players
    }
  end

  # ---- helpers ----

  defp add_dir_entry!(store, parent, name, child, sc) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, child)
    {metadata, commit_opts} = SignedWrite.opts_for(parent, store: store, signing_context: sc)

    _ =
      CommitStoreClient.create_chained_commit(
        store,
        parent,
        Encoding.encode_update(schema),
        metadata,
        commit_opts
      )

    :ok
  end

  # A citizen-authored object: node-GENESIS meta, zoned under a player home
  # (players/), a node-held possession token (mint-at-create). Returns {home, obj}.
  defp gift_scaffold(store, node_ctx, players) do
    {:ok, home} =
      ChildMutation.create_zone_root(
        players,
        "fable-home-#{:rand.uniform(1_000_000_000)}",
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Fable's Home", description: "a warm room"}),
        store
      )

    {:ok, obj} =
      ChildMutation.create_zoned_child(
        home,
        "glowbug.obj",
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "glowbug"}),
        store,
        signing_context: node_ctx
      )

    {home, obj}
  end

  defp save_verb!(store, host, node_ctx, name, body) do
    :ok = VerbSource.save_safe_verb(host, name, body, [host], store, signing_context: node_ctx)
  end

  defp run!(store, ctx, obj, verb) do
    facade = %{Facade.new(ctx, obj, [obj], nil, store) | host_kind: :object}
    VerbSource.run_safe_verb(obj, verb, [obj], facade, %{}, store)
  end

  defp holder_ctx(store, root, room, name, identity) do
    {pub, priv} = Signing.generate_keypair()

    %{
      player_name: name,
      player_uuid: UUID.uuid4(),
      player_dir_uuid: UUID.uuid4(),
      inventory_uuid: UUID.uuid4(),
      current_room_uuid: room,
      presence_filename: "#{name}.usr",
      root_uuid: root,
      store: store,
      signing_context: %SigningContext{
        identity_uuid: identity,
        private_key: priv,
        public_key: pub
      },
      signer_id: nil,
      cert_cids: []
    }
  end

  defp state_val(store, obj, key) do
    {:ok, schema} = Schemas.load_dir_schema(obj, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.object_filename())
    {:ok, doc} = DocBuilder.reconstruct_doc(store, entry.node_id)
    get_in(Jason.decode!(ContentType.get_content(doc)), ["state", key])
  end

  defp give!(obj, from, to) do
    {:ok, _} = BursarClient.transfer(Bursar, obj, from, to, authenticated_as: from)
    :ok
  end

  @rub ~s|Commonplace.MUD.World.Facade.put_state(world, "rubs", "yes")|

  # ---- PIN 1: the gift works for the recipient who HOLDS it ----

  test "PIN 1: a gifted object's verb state-write persists for the recipient who HOLDS it",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root,
         players: players
       } do
    {home, glowbug} = gift_scaffold(store, node_ctx, players)
    save_verb!(store, glowbug, node_ctx, "rub", @rub)

    assert Trust.doc_zone(glowbug, store) == home
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, glowbug)

    quill_id = "quill-#{:rand.uniform(1_000_000_000)}"
    give!(glowbug, node_identity, quill_id)
    assert {:held, %{holder: ^quill_id}} = BursarClient.query(Bursar, glowbug)

    quill = holder_ctx(store, root, home, "quill", quill_id)
    assert {:ok, _} = run!(store, quill, glowbug, "rub")
    assert state_val(store, glowbug, "rubs") == "yes"
  end

  # ---- PIN 2: anti-grief — a non-holder non-author is refused ----

  test "PIN 2 (ANTI-GRIEF): a non-holder non-author cannot drive a player-zoned object's state",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root,
         players: players
       } do
    {home, glowbug} = gift_scaffold(store, node_ctx, players)
    save_verb!(store, glowbug, node_ctx, "rub", @rub)

    # node still holds the token; mallory holds nothing and authored nothing.
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, glowbug)
    mallory = holder_ctx(store, root, home, "mallory", "mallory-#{:rand.uniform(1_000_000_000)}")

    assert {:ok, _} = run!(store, mallory, glowbug, "rub")
    # No standing (not holder, not author, not in-zone) → put_state refused.
    assert state_val(store, glowbug, "rubs") == nil
  end

  # ---- PIN 3: scope isolation — a holder can't possession-elevate a move ----

  test "PIN 3 (SCOPE ISOLATION): a holder cannot possession-elevate a non-state write (move_object)",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root,
         players: players
       } do
    {home, glowbug} = gift_scaffold(store, node_ctx, players)
    {:ok, dest} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    add_dir_entry!(store, root, "dest", dest, node_ctx)

    save_verb!(store, glowbug, node_ctx, "rub", @rub)

    save_verb!(
      store,
      glowbug,
      node_ctx,
      "teleport",
      ~s|Commonplace.MUD.World.Facade.move_object(world, "#{dest}")|
    )

    quill_id = "quill-#{:rand.uniform(1_000_000_000)}"
    give!(glowbug, node_identity, quill_id)
    quill = holder_ctx(store, root, home, "quill", quill_id)

    # Holder CAN drive state (put_state elevates)...
    assert {:ok, _} = run!(store, quill, glowbug, "rub")
    assert state_val(store, glowbug, "rubs") == "yes"

    # ...but CANNOT possession-elevate a move: move_object uses the token-blind
    # write_guarded, so the holder gets no elevation there → the object never
    # moves into dest.
    assert {:ok, _} = run!(store, quill, glowbug, "teleport")
    refute Enum.any?(World.list_objects_in(dest, store), &(&1.node_id == glowbug))
    assert Enum.any?(World.list_objects_in(home, store), &(&1.node_id == glowbug))
  end

  # ---- PIN 4: firewall — a holder's state-write can't touch the zone stamp ----

  test "PIN 4 (FIREWALL): a holder's state-write cannot re-stamp the object, and the state_only firewall refuses a non-state write",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root,
         players: players
       } do
    {home, glowbug} = gift_scaffold(store, node_ctx, players)
    # A verb that TRIES to write "zone" — but put_state nests everything under the
    # "state" submap, so it can only ever reach state["zone"], never meta["zone"].
    save_verb!(
      store,
      glowbug,
      node_ctx,
      "tamper",
      ~s|Commonplace.MUD.World.Facade.put_state(world, "zone", "evil-zone")|
    )

    quill_id = "quill-#{:rand.uniform(1_000_000_000)}"
    give!(glowbug, node_identity, quill_id)
    quill = holder_ctx(store, root, home, "quill", quill_id)

    zone_before = Trust.doc_zone(glowbug, store)
    assert zone_before == home

    # (a) the holder's elevated put_state lands in state["zone"] — the node-signed
    # zone STAMP (meta["zone"]) is structurally untouchable → no re-homing.
    assert {:ok, _} = run!(store, quill, glowbug, "tamper")
    assert state_val(store, glowbug, "zone") == "evil-zone"
    assert Trust.doc_zone(glowbug, store) == zone_before

    # (b) the firewall FIRES (not vacuous): a genuine non-state write under
    # :state_only is REFUSED, even node-signed — proving the AXIS-2-override guard.
    assert {:error, :state_firewall} =
             World.set_meta(glowbug, Schemas.object_filename(), "zone", "escape", store,
               state_only: true,
               signing_context: node_ctx
             )

    assert Trust.doc_zone(glowbug, store) == zone_before
  end
end
