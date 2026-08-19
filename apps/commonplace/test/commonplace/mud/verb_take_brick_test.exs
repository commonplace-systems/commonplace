defmodule Commonplace.MUD.VerbTakeBrickTest do
  @moduledoc """
  CX-55o3 — verb-authoring must NOT brick object takeability (the M3 prereq).

  Root cause (reproduced, plan #7698): a @created object's take runs the ELEVATED
  node-push path (the citizen can't write their own node-owned inventory dir), and
  that path judged node-ownership by the object dir schema's LATEST-COMMIT SIGNER.
  Authoring a verb re-chains the object's own dir schema with the AUTHOR's
  signature (the `verbs/` entry-add — the correct L3 carve), flipping the
  latest-signer to the citizen → node_owned? false → take refused. Same class as
  the CX-ix9n presence re-chain, but the OBJECT schema is re-chained by @verb.

  The fix (plan-ruled, #7698/#7701/#7702): judge node-ownership by the ACTUAL
  ownership RECORD — the node-held possession TOKEN — not the fragile
  latest-signer PROXY. mint-at-create makes a @created/curated object node-held;
  @verb/@desc/presence re-chain the schema but NEVER the token.

  The FOUR pins plan required:
    1. @create → take → drop → @verb → take  — take still works after authoring.
    2. ANTI-THEFT — a player-held item is NOT node-elevate-takeable.
    3. FORK-TRANSPLANT — a deep-copy fork gets a fresh uuid with NO token
       (Guardrail A: the token is Bursar-external + uuid-bound, un-transplantable).
    4. MINT-SITE — a doc that merely appears (raw write / no deliberate mint) gets
       NO node-held token (Guardrail B: node-held token ⟺ deliberate node mint).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}

  alias Commonplace.MUD.{
    Citizenship,
    Parser,
    Schemas,
    SignedWrite,
    Take,
    VerbSource,
    Verbs,
    World
  }

  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{Fork, Schema}
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_brick_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"brick_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"brick_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"brick_tss_#{n}",
       pending_imports_name: :"brick_pi_#{n}"}
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

    root = mk_dir!(store, node_ctx)
    players = mk_dir!(store, node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      players: players
    }
  end

  # ---- seed helpers (mirror take_test.exs) ----

  defp mk_dir!(store, sc) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: sc)
    uuid
  end

  defp mk_room!(store, sc, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "x"}),
        store,
        signing_context: sc
      )

    uuid
  end

  defp mk_object!(store, sc, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: sc
      )

    uuid
  end

  defp share!(store, root, room, sc) do
    add_dir_entry!(store, root, "room-#{String.slice(room, 0, 8)}", room, sc)
    room
  end

  defp add_dir_entry!(store, parent, name, child, sc) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, child)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent, store: store, signing_context: sc)
    _ = CommitStoreClient.create_chained_commit(store, parent, update, metadata, commit_opts)
    :ok
  end

  defp entry_names(store, dir) do
    {:ok, schema} = Schemas.load_dir_schema(dir, store)
    schema |> Schema.entries() |> Map.keys()
  end

  defp fresh do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    {id, %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end

  # ---- PIN 1: take still works after authoring a verb on the object ----

  test "PIN 1: @create → take → drop → @verb → take — a verb-bearing object stays takeable", %{
    store: store,
    root: root
  } do
    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    citizen = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}

    {:ok, %{cert_cids: cids, home_room_uuid: home}} =
      Citizenship.ensure(pid, pub, "builder", root, store)

    {:ok, home_schema} = Schemas.load_dir_schema(home, store)
    {:ok, %Schema.Entry{node_id: inventory}} = Schema.get_entry(home_schema, "inventory")

    ctx = %{
      player_name: "builder",
      current_room_uuid: home,
      inventory_uuid: inventory,
      root_uuid: root,
      store: store,
      signing_context: citizen,
      cert_cids: cids,
      signer_id: Signing.signer_id(pid, pub)
    }

    disp = fn line -> Verbs.dispatch(Parser.parse(line), ctx) end

    assert {:reply, _} = disp.("@create object gizmo")
    assert {:reply, "You take gizmo."} = disp.("take gizmo")
    assert {:reply, _} = disp.("drop gizmo")

    # Author a real safe-verb on the object — this is the step that (pre-fix)
    # re-chained the object dir schema citizen-signed and bricked take.
    {:ok, gizmo} = World.find_entry_by_name(home, "gizmo", store)
    assert {:enter_editor, %{editable: true}} = disp.("@verb gizmo:poke")

    assert :ok =
             VerbSource.save_safe_verb(gizmo.node_id, "poke", "\"poke\"", [gizmo.node_id], store,
               signing_context: citizen,
               cert_cids: cids,
               signer_id: nil
             )

    # The bricked case: pre-fix this was {:error, "You can't take that."}
    assert {:reply, "You take gizmo."} = disp.("take gizmo")
    assert "gizmo-#{String.slice(gizmo.node_id, 0, 8)}.obj" in entry_names(store, inventory)
  end

  # ---- PIN 2: anti-theft — a player-held item is NOT node-elevate-takeable ----

  test "PIN 2 (ANTI-THEFT): a node-schema-signed item whose token is PLAYER-held cannot be node-elevate-taken",
       %{
         store: store,
         node_ctx: node_ctx,
         root: root
       } do
    room = share!(store, root, mk_room!(store, node_ctx, "Gallery"), node_ctx)
    inventory = mk_dir!(store, node_ctx)
    # Node-created (node-signed schema), so ONLY the token distinguishes ownership.
    item = mk_object!(store, node_ctx, "widget")
    add_dir_entry!(store, room, "widget.obj", item, node_ctx)

    # A player HOLDS the item's possession token (as if carrying it).
    {holder_id, _} = fresh()

    {:ok, _} =
      BursarClient.acquire(Bursar, item, holder_id, authenticated_as: holder_id, ttl: nil)

    {taker_id, _} = fresh()

    # Token is held-by-OTHER → node_owns_item? false → refuse, BEFORE the schema
    # fallback (which would spuriously pass on the node-signed schema). This is
    # the anti-theft pin: possession beats the proxy.
    assert {:error, :not_takeable_here} =
             Take.take(item, "widget.obj", room, inventory, taker_id,
               store: store,
               root_uuid: root
             )

    assert "widget.obj" in entry_names(store, room)
    assert {:held, %{holder: ^holder_id}} = BursarClient.query(Bursar, item)
  end

  # ---- PIN 3: fork-transplant — a deep-copy fork carries NO token ----

  test "PIN 3 (FORK-TRANSPLANT): a fork of a node-held item is NOT node-owned through EITHER the token OR the schema-signer fallback",
       %{
         store: store,
         node_ctx: node_ctx,
         root: root
       } do
    room = share!(store, root, mk_room!(store, node_ctx, "Gallery"), node_ctx)
    inventory = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "relic")
    {:ok, node_identity} = NodeIdentity.identity()

    {:ok, _} =
      BursarClient.acquire(Bursar, item, node_identity, authenticated_as: node_identity, ttl: nil)

    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)

    # Deep-copy fork → a brand-new uuid subtree (fork.ex remaps every uuid).
    fork_uuid = Fork.fork_directory(item, store)
    refute fork_uuid == item

    # (A) TOKEN doesn't transplant — the token is Bursar-external + uuid-bound,
    # so the fresh-uuid copy is unheld.
    assert :available = BursarClient.query(Bursar, fork_uuid)

    # (FALLBACK safety) the :available branch falls back to the schema-signer
    # check — so the fork must ALSO fail THAT. Fork creates fresh commits with NO
    # node signing context, so the fork's own schema commit does NOT parse to the
    # node identity. (node_owned? reads signer_id; the enforce gate guarantees a
    # stored signer_id is authentic, and a fork carries none.) This is the exact
    # condition plan #7709 required proven-by-test, not argued.
    # (mirror node_owned?'s exact logic: :none OR non-node signer → false)
    fork_node_signed? =
      case CommitStoreClient.latest_commit(store, fork_uuid) do
        {:ok, c} -> match?({:ok, ^node_identity, _}, Signing.parse_signer_id(c.signer_id || ""))
        _ -> false
      end

    refute fork_node_signed?

    # (B) END-TO-END: taking the fork from a VALID shared-curated room (zone-gate
    # + node-owned inventory both pass, so the ONLY gate that can refuse is
    # node_owns_item?) is refused — the fork inherits node-ownership through
    # NEITHER the token NOR the fallback.
    add_dir_entry!(store, room, "relic.obj", fork_uuid, node_ctx)
    {taker_id, _} = fresh()

    assert {:error, :not_takeable_here} =
             Take.take(fork_uuid, "relic.obj", room, inventory, taker_id,
               store: store,
               root_uuid: root
             )

    assert "relic.obj" in entry_names(store, room)
  end

  # ---- PIN 4: mint-site — a doc that merely appears gets NO node-held token ----

  test "PIN 4 (MINT-SITE): a raw-written object doc (no deliberate mint) has NO node-held token",
       %{
         store: store,
         node_ctx: node_ctx
       } do
    # A raw create_dir_with_meta (mirrors a raw MCP write / import surfacing a
    # doc) — NOT the @create/curated ChildMutation mint path. No token is minted.
    raw = mk_object!(store, node_ctx, "driftwood")
    assert :available = BursarClient.query(Bursar, raw)
  end
end
