defmodule Commonplace.MUD.CxCoo8GrantRewardTest do
  @moduledoc """
  CX-coo8 — pins for `Facade.grant/2`, the WORLD REWARD GRANT primitive.

  `grant/2` mints a new object into the invoker's inventory as a node-signed
  "the world grants you this" reward, guarded by TWO ORTHOGONAL axes (both
  load-bearing, both fail-closed):

    * ANTI-FARM (host-gate): node-signs the mint ONLY when the calling verb's
      HOST resolves node-owned authority (`object_owner_authority`) — a
      citizen's own (non-node-owned) host resolves `:none` and the grant is
      REFUSED, so a citizen can't author a "gimme" verb to farm free items.
    * ANTI-FORGE (zone-stamp): the freshly minted object is node-genesis (so
      naively `node_owned?` would read TRUE — a forge) but its meta `"zone"`
      is stamped to the recipient's `players/`-zone, which flips AXIS 2
      (`Take.player_zone?`) to TRUE and so `node_owned?` reads FALSE overall
      — the reward is genuinely the PLAYER's, never curated-in-hand.

  This file does NOT modify `grant/2` — it only pins the existing behavior,
  calling the primitive DIRECTLY (not via `Verbs.dispatch`) so the exact
  error/success tuples are asserted precisely.

  DISCREPANCY FROM THE ORIGINAL TASK BRIEF (documented, not a weakening):
  `Commonplace.MUD.World.Facade` wraps EVERY public method's return through
  `AccumDef`/`__accumulate__/2` (CX-3x5a), which is a load-bearing
  RETURN-sanitization boundary — it fires at the `def` call boundary itself,
  UNCONDITIONALLY, including a bare/direct test call (the module doc for
  `__accumulate__/2` says so explicitly: "this same `def` boundary, in tests
  calling a facade method directly"). So a direct `Facade.grant/2` call does
  NOT return the raw internal reason atom — it returns `{:error,
  sanitize_reason(reason)}`, and NONE of `:not_grantable_host`,
  `:no_recipient_zone`, `:no_inventory`, `:recipient_not_zoned` are in the
  explicit allowlist (`sanitize_reason/1`), so they ALL sanitize to the
  generic `{:error, :refused}` on the returned value. Asserting the literal
  raw tuples as originally briefed is IMPOSSIBLE without either weakening the
  pins (collapsing PIN 1 / PIN 4a / PIN 4b into indistinguishable `:refused`
  — which would make them vacuous with respect to each other) or bypassing
  the facade's own documented sanitization contract.

  Resolution: use the facade's OWN drain-accumulator, `Facade.drain_errors/0`
  (public, `@doc false`, the same seam `emit_verb_drops/2` uses in
  production) to read the RAW recorded reason immediately after each call,
  in ADDITION to asserting the sanitized value the caller actually receives.
  This keeps every pin exact and non-vacuous while staying faithful to what
  the primitive actually does.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{ChildMutation, Schemas, SignedWrite, Take}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.MUD.World
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_coo8_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"coo8_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"coo8_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"coo8_tss_#{n}",
       pending_imports_name: :"coo8_pi_#{n}"}
    )

    # CITIZEN identity — used to genesis-sign a non-node host object (the
    # anti-farm PIN 1 host).
    {citizen_pub, citizen_priv} = Signing.generate_keypair()
    citizen_identity = "coo8-citizen-#{n}"
    citizen_ctx = %SigningContext{identity_uuid: citizen_identity, private_key: citizen_priv, public_key: citizen_pub}

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{
        citizen_identity => Signing.encode_key(citizen_pub)
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

    # World root with a `players/` anchor.
    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    {:ok, players} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    # A durable RECIPIENT: a player home zone-root under players/, plus an
    # inventory dir under it.
    {:ok, player_dir} =
      ChildMutation.create_zone_root(
        players,
        "alice-home",
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Alice's Home", description: "a cozy room"}),
        store
      )

    {:ok, inventory} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    add_dir_entry!(store, player_dir, "inventory", inventory, node_ctx)

    # Confirm the precondition that makes the pins non-vacuous: the recipient
    # zone really IS a players/-reachable zone.
    assert Take.player_zone?(player_dir, root, store)

    # Invoker identity — holds the signing_context for ctx-building. Not in
    # trusted_identities (the grant path node-signs the mint; the invoker's
    # own authority is irrelevant to grant's anti-farm/anti-forge gates).
    {invoker_pub, invoker_priv} = Signing.generate_keypair()
    invoker_id = "coo8-invoker-#{n}"
    invoker_sc = %SigningContext{identity_uuid: invoker_id, private_key: invoker_priv, public_key: invoker_pub}

    # A NODE-owned host (curated) — the success-path HOST.
    node_host = curated_object!(store, node_ctx, "warded vault")

    # A CITIZEN-owned host — genesis-signed by the citizen, NOT the node, so
    # `object_owner_authority` resolves `:none` for it.
    citizen_host = curated_object!(store, citizen_ctx, "citizen's shed")

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      players: players,
      player_dir: player_dir,
      inventory: inventory,
      invoker_id: invoker_id,
      invoker_sc: invoker_sc,
      node_host: node_host,
      citizen_host: citizen_host
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

  # A curated (genesis-signed-by-`sc`) object, UNZONED.
  defp curated_object!(store, sc, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: sc
      )

    uuid
  end

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

  defp inv_count(store, inv) do
    {:ok, schema} = Schemas.load_dir_schema(inv, store)
    length(Schema.list_entries(schema))
  end

  defp reward_zone(store, uuid), do: Trust.doc_zone(uuid, store)

  # Ctx builder for a direct grant call — a REAL recipient by default.
  defp grant_ctx(%{
         root: root,
         store: store,
         player_dir: player_dir,
         inventory: inventory,
         invoker_sc: invoker_sc
       }) do
    %{
      player_name: "grantee",
      player_uuid: UUID.uuid4(),
      player_dir_uuid: player_dir,
      inventory_uuid: inventory,
      current_room_uuid: player_dir,
      root_uuid: root,
      store: store,
      signing_context: invoker_sc,
      signer_id: nil,
      cert_cids: []
    }
  end

  defp grant_facade(ctx, host_uuid, store) do
    %{Facade.new(ctx, host_uuid, MapSet.new([host_uuid]), {host_uuid, "reward"}, store) | host_kind: :object}
  end

  # ---- PIN 1: anti-farm — citizen host is refused, no mint ----

  test "PIN 1: a CITIZEN-owned host is refused (anti-farm host-gate), no mint", %{
    store: store,
    citizen_host: citizen_host,
    inventory: inventory
  } = ctx do
    before_count = inv_count(store, inventory)

    facade = grant_facade(grant_ctx(ctx), citizen_host, store)
    _ = Facade.drain_errors()

    # Sanitized value the verb body actually receives.
    assert Facade.grant(facade, "gold ingot") == {:error, :refused}
    # Raw internal reason (via the facade's own drain-accumulator seam) —
    # proves it's the HOST-GATE specifically, not a generic refusal.
    assert Facade.drain_errors() == [{:grant, :not_grantable_host}]
    assert inv_count(store, inventory) == before_count
  end

  # ---- PIN 1b: node host lands + node_owned? is FALSE (both axes) ----

  test "PIN 1b: a NODE-owned host mints + the reward is node-genesis but player-zoned (node_owned? FALSE)",
       %{
         store: store,
         root: root,
         node_host: node_host,
         node_identity: node_identity,
         player_dir: player_dir,
         inventory: inventory
       } = ctx do
    before_count = inv_count(store, inventory)

    facade = grant_facade(grant_ctx(ctx), node_host, store)

    assert {:ok, reward} = Facade.grant(facade, "gold ingot")

    # AXIS 1: node genesis == TRUE.
    assert meta_genesis_signer(store, reward) == node_identity

    zone = reward_zone(store, reward)
    # Non-vacuous: a REAL non-nil players/-reachable uuid, not nil.
    assert is_binary(zone)
    assert zone == player_dir
    # AXIS 2 veto fires: the zone IS positively a players/-zone.
    assert Take.player_zone?(zone, root, store) == true

    # node_owned? = AXIS1(true) AND NOT AXIS2(true) = FALSE → forge closed.
    # (`node_owned?/3` is private; the two axes asserted above ARE the proof.)

    assert inv_count(store, inventory) == before_count + 1
  end

  # ---- PIN 2: invoker POSSESSES the reward ----

  test "PIN 2: the invoker holds the reward's possession token", %{
    store: store,
    node_host: node_host,
    invoker_id: invoker_id
  } = ctx do
    facade = grant_facade(grant_ctx(ctx), node_host, store)

    assert {:ok, reward} = Facade.grant(facade, "gold ingot")

    assert {:held, %{holder: ^invoker_id}} = BursarClient.query(Bursar, reward)
  end

  # ---- PIN 4: fail-CLOSED on no recipient zone ----

  test "PIN 4a: nil player_dir_uuid -> {:error, :no_recipient_zone}, no mint even though the host would allow", %{
    store: store,
    node_host: node_host,
    inventory: inventory
  } = ctx do
    before_count = inv_count(store, inventory)

    ctx_map = %{grant_ctx(ctx) | player_dir_uuid: nil}
    facade = grant_facade(ctx_map, node_host, store)
    _ = Facade.drain_errors()

    assert Facade.grant(facade, "gold ingot") == {:error, :refused}
    assert Facade.drain_errors() == [{:grant, :no_recipient_zone}]
    assert inv_count(store, inventory) == before_count
  end

  test "PIN 4b: a fresh players/-unreachable player_dir_uuid -> {:error, :recipient_not_zoned}, no mint", %{
    store: store,
    node_host: node_host,
    inventory: inventory
  } = ctx do
    before_count = inv_count(store, inventory)

    stray_uuid = UUID.uuid4()
    ctx_map = %{grant_ctx(ctx) | player_dir_uuid: stray_uuid}
    facade = grant_facade(ctx_map, node_host, store)
    _ = Facade.drain_errors()

    assert Facade.grant(facade, "gold ingot") == {:error, :refused}
    assert Facade.drain_errors() == [{:grant, :recipient_not_zoned}]
    assert inv_count(store, inventory) == before_count
  end

  # ---- PIN 5: the zone stamp is DURABLE across a later legit meta write ----

  test "PIN 5: a later node-signed surgical meta merge preserves the zone stamp (delayed-forge check)", %{
    store: store,
    root: root,
    node_ctx: node_ctx,
    node_host: node_host,
    player_dir: player_dir
  } = ctx do
    facade = grant_facade(grant_ctx(ctx), node_host, store)

    assert {:ok, reward} = Facade.grant(facade, "gold ingot")
    assert reward_zone(store, reward) == player_dir

    # A LATER legit meta write (node-signed surgical merge into meta["state"]).
    # `set_attr/2` is a deprecated no-op (see Facade module doc), so
    # `merge_meta`/`put_state` is the meaningful later-write to check here.
    assert :ok =
             World.merge_meta(
               reward,
               Schemas.object_filename(),
               %{"state" => %{"touched" => true}},
               store,
               signing_context: node_ctx
             )

    # The zone stamp survived the later write — node_owned? stays FALSE.
    zone = reward_zone(store, reward)
    assert zone == player_dir
    assert Take.player_zone?(zone, root, store) == true
  end
end
