defmodule Commonplace.MUD.CxE8xjGiftedStateTest do
  @moduledoc """
  CX-e8xj — REPRODUCE-FIRST (plan review pending). "A gift has to work."

  A citizen A `@creates` an object (node-GENESIS meta via ChildMutation, zoned
  under A's home = `players/`) and authors a `put_state` verb on it. A gives it
  to B (the possession TOKEN transfers to B, the object dir moves to B's
  inventory). B invokes the verb: the verb's `say` fires, but the `put_state` is
  SILENTLY DROPPED (B holds the object but has no write-authority over its meta,
  and the CX-orlm AXIS 2 veto correctly refuses NODE-elevation onto a
  `players/`-zoned object) → the gifted interactable loses function for its
  recipient, with a contradictory "Nothing happens" notice.

  Root (this test pins it): `Facade.object_owner_authority` resolves elevation by
  node-ownership (genesis + zone) ONLY — it never consults the possession TOKEN.
  So a legitimate HOLDER who is neither the author nor in the object's zone gets
  `:none` → the state write runs invoker-signed → enforce refuses it.

  DESIGN TARGET (plan to rule, report-before-code): HOLDER-WRITABLE STATE —
  whoever holds the object's possession token may drive its runtime STATE
  (put_state/get_state), SCOPED to the object's own state, while the verb CODE
  stays AUTHOR-signed (RCE-safe). possession → state-write authority; authorship
  → code-write authority. This test asserts the DESIRED outcome (holder's
  put_state persists), so it is RED against the token-blind resolver.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{ChildMutation, Schemas, SignedWrite, VerbSource}
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

    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    {:ok, players} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    %{store: store, node_ctx: node_ctx, node_identity: node_identity, root: root, players: players}
  end

  # ---- helpers ----

  defp add_dir_entry!(store, parent, name, child, sc) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, child)
    {metadata, commit_opts} = SignedWrite.opts_for(parent, store: store, signing_context: sc)
    _ = CommitStoreClient.create_chained_commit(store, parent, Encoding.encode_update(schema), metadata, commit_opts)
    :ok
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
      signing_context: %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub},
      signer_id: nil,
      cert_cids: []
    }
  end

  defp rubs(store, obj) do
    {:ok, schema} = Schemas.load_dir_schema(obj, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.object_filename())
    {:ok, doc} = DocBuilder.reconstruct_doc(store, entry.node_id)
    get_in(Jason.decode!(ContentType.get_content(doc)), ["state", "rubs"])
  end

  test "a gifted object's verb state-write persists for the recipient who HOLDS it",
       %{store: store, node_ctx: node_ctx, node_identity: node_identity, root: root, players: players} do
    # Author A's home (a player zone under players/).
    {:ok, home} =
      ChildMutation.create_zone_root(
        players,
        "fable-home",
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Fable's Home", description: "a warm room"}),
        store
      )

    # A @creates glowbug in their home: node-GENESIS meta, zone == home (under
    # players/), and a node-held possession token (mint-at-create).
    {:ok, glowbug} =
      ChildMutation.create_zoned_child(
        home,
        "glowbug.obj",
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "glowbug"}),
        store,
        signing_context: node_ctx
      )

    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "rubs", "yes")|
    assert :ok = VerbSource.save_safe_verb(glowbug, "rub", body, [glowbug], store, signing_context: node_ctx)

    # Sanity on the shape: node-genesis, player-zoned, node holds the token.
    assert Trust.doc_zone(glowbug, store) == home
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, glowbug)

    # A GIVES glowbug to B (quill): the possession token transfers to quill.
    quill_id = "quill-#{:rand.uniform(1_000_000_000)}"
    assert {:ok, _} = BursarClient.transfer(Bursar, glowbug, node_identity, quill_id, authenticated_as: node_identity)
    assert {:held, %{holder: ^quill_id}} = BursarClient.query(Bursar, glowbug)

    # B rubs it. The verb code (node-authored) dispatches; the put_state must
    # persist BECAUSE quill holds the object (holder-writable state).
    quill = holder_ctx(store, root, home, "quill", quill_id)
    facade = %{Facade.new(quill, glowbug, [glowbug], nil, store) | host_kind: :object}

    assert {:ok, _} = VerbSource.run_safe_verb(glowbug, "rub", [glowbug], facade, %{}, store)

    # DESIRED: the gift works for its recipient. RED against the token-blind
    # resolver (put_state refused → rubs stays nil).
    assert rubs(store, glowbug) == "yes"
  end
end
