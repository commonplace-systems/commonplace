defmodule Commonplace.MUD.PlayerSessionIdentityTest do
  @moduledoc """
  CX-lg06 acceptance test — the MUD game loop signs as the player.

  Mirrors the strict+enforce named-store scaffold from
  `Commonplace.MUD.SectionOwnershipTest` (CX-qat5.4), but drives writes
  through the REAL dispatch path — `Commonplace.MUD.PlayerSession` →
  `Commonplace.MUD.Verbs.dispatch/2` — instead of calling
  `CommitStoreClient` directly, to prove the session-identity threading
  reaches every commit-producing verb call, not just a hand-built one.

  Player X holds a section cert covering room1 (both the room's
  directory doc AND its `__room.json` metadata doc — a section cert's
  scope is a concrete uuid list, so both docs a room-metadata edit
  touches must be listed; see `Commonplace.MUD.Sections` moduledoc).
  `@name here <name>` (`Commonplace.MUD.Verbs.do_rename/2` →
  `World.set_meta/6` → `Schemas.write_meta_doc/4`) lands the edit
  signed AND capability-proofed. Player Y, registered/signed but
  holding NO cert, gets the identical command DENIED — verified at BOTH
  the store level (the room's metadata head does not move) AND the verb
  reply level (CX-93ea closed the gap this moduledoc used to describe:
  the MUD verb layer now checks every create_commit/create_chained_commit
  result and surfaces a `{:error, {:trust_rejected, _}}` as a
  player-visible "you don't have permission" reply instead of a false
  `:ok`).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
  alias Commonplace.MUD.{PlayerSession, Sections}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_identity_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"mi_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"mi_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"mi_tss_#{n}",
       pending_imports_name: :"mi_pi_#{n}"}
    )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_mud_identity_secrets_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(secrets_dir)
    secrets_name = :"mi_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets_name)

    # CX-el97: the move path (`Move.move`) takes a bursar move-lock; without a
    # running Bursar the lock acquire fails and masks EVERY move as a generic
    # failure. Start one (default name) so the denied-move test exercises the
    # real trust-denial path, not a bursar-unavailable artifact.
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(root_uuid: UUID.uuid4(), store: name, sweep_interval: 60_000)

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      if Process.alive?(secrets_pid), do: GenServer.stop(secrets_pid)
      if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid)
      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    {root_pub, root_priv} = Signing.generate_keypair()

    root_ctx = %SigningContext{identity_uuid: "root", private_key: root_priv, public_key: root_pub}

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{"root" => Signing.encode_key(root_pub)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    # Two SEPARATE roots (CX-lg06 debugging note): `register_player`'s
    # cold identities use the same `name.usr` honorific-extension
    # convention as MUD `Presence` — sharing one root between the
    # identity registry and the MUD world tree means
    # `PlayerSession.find_presence/3`'s walk matches the IDENTITY
    # registry's `"x.usr"` entry (under `__identities__`) before ever
    # reaching the real presence entry under `room1`. Keeping them
    # separate (as any real deployment would — the identity root is
    # workspace-wide, the MUD world root is one app's tree within it)
    # avoids the collision entirely.
    identity_root_uuid = UUID.uuid4()
    genesis(store: name, uuid: identity_root_uuid, schema_doc: Schema.new_schema(), ctx: root_ctx)

    root_uuid = UUID.uuid4()
    genesis(store: name, uuid: root_uuid, schema_doc: Schema.new_schema(), ctx: root_ctx)

    {:ok, x_uuid, x_pub} =
      Identity.register_player("x", identity_root_uuid, name, signing_context: root_ctx, secret_store: secrets_name)

    {:ok, y_uuid, y_pub} =
      Identity.register_player("y", identity_root_uuid, name, signing_context: root_ctx, secret_store: secrets_name)

    # --- players/x, players/y directories (root-signed) ---
    players_dir = new_dir(name, root_ctx)
    x_dir = new_dir_with_meta(name, root_ctx, Commonplace.MUD.Schemas.player_filename(), player_json("x"))
    x_inv = new_dir(name, root_ctx)
    y_dir = new_dir_with_meta(name, root_ctx, Commonplace.MUD.Schemas.player_filename(), player_json("y"))
    y_inv = new_dir(name, root_ctx)

    add_directory(name, root_ctx, x_dir, "inventory", x_inv)
    add_directory(name, root_ctx, y_dir, "inventory", y_inv)
    add_directory(name, root_ctx, players_dir, "x", x_dir)
    add_directory(name, root_ctx, players_dir, "y", y_dir)
    add_directory(name, root_ctx, root_uuid, "players", players_dir)

    # --- room2 (the destination for the CX-el97 denied-move test) ---
    room2_meta = new_text_doc(name, root_ctx, room_json("Room Two", %{}))
    room2_dir = new_dir(name, root_ctx)
    add_file(name, root_ctx, room2_dir, Commonplace.MUD.Schemas.room_filename(), room2_meta)
    add_directory(name, root_ctx, root_uuid, "room2", room2_dir)

    # --- room1 (dir + __room.json meta doc). A real EAST exit to room2 (CX-el97:
    # a denied move on a REAL exit must report permission, not a fake dead-end).
    # NORTH is deliberately left exit-free — the @dig-denied test digs north. ---
    room1_meta = new_text_doc(name, root_ctx, room_json("Room One", %{"east" => room2_dir}))
    room1_dir = new_dir(name, root_ctx)
    add_file(name, root_ctx, room1_dir, Commonplace.MUD.Schemas.room_filename(), room1_meta)
    add_directory(name, root_ctx, root_uuid, "room1", room1_dir)

    # --- presence: both x and y start in room1 ---
    x_presence = new_map_doc(name, root_ctx, "x", "usr", x_uuid)
    y_presence = new_map_doc(name, root_ctx, "y", "usr", y_uuid)
    add_file(name, root_ctx, room1_dir, "x.usr", x_presence)
    add_file(name, root_ctx, room1_dir, "y.usr", y_presence)

    {:ok, x_ctx} = AgentKeys.signing_context_for(x_uuid, secrets_name)
    {:ok, _y_ctx} = AgentKeys.signing_context_for(y_uuid, secrets_name)

    # X holds a section cert over room1's dir AND meta doc.
    assert {:ok, cap} =
             Sections.issue_section(root_ctx, {x_uuid, x_pub}, [room1_dir, room1_meta], store: name)

    %{
      store: name,
      secrets: secrets_name,
      root_uuid: root_uuid,
      room1_dir: room1_dir,
      room1_meta: room1_meta,
      room2_dir: room2_dir,
      x_uuid: x_uuid,
      x_pub: x_pub,
      x_ctx: x_ctx,
      y_uuid: y_uuid,
      y_pub: y_pub,
      cap: cap
    }
  end

  test "a session whose player holds a section cert writes signed+proofed; a session without one is denied",
       %{
         store: store,
         secrets: secrets,
         root_uuid: root_uuid,
         room1_dir: room1_dir,
         room1_meta: room1_meta,
         x_uuid: x_uuid,
         x_pub: x_pub,
         y_uuid: y_uuid,
         cap: cap
       } do
    {:ok, x_pid} =
      PlayerSession.start_link(
        player_name: "x",
        root_uuid: root_uuid,
        store: store,
        buffered: true,
        player_identity_uuid: x_uuid,
        secret_store: secrets,
        cert_cids: [cap.id]
      )

    assert :sys.get_state(x_pid).current_room_uuid == room1_dir

    :ok = PlayerSession.input_sync(x_pid, "@name here Renamed-By-X")
    _ = PlayerSession.drain_buffer(x_pid)
    PlayerSession.stop(x_pid)

    assert {:ok, x_head} = CommitStore.latest_commit(store, room1_meta)
    assert x_head.metadata[:capability_proof] == cap.id
    assert x_head.signer_id == Signing.signer_id(x_uuid, x_pub)
    assert {:ok, x_doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, room1_meta)
    assert {:ok, %{"name" => "Renamed-By-X"}} = Jason.decode(ContentType.get_content(x_doc))

    # --- Y: registered, signed, holds NO cert over room1 — denied. ---
    {:ok, y_pid} =
      PlayerSession.start_link(
        player_name: "y",
        root_uuid: root_uuid,
        store: store,
        buffered: true,
        player_identity_uuid: y_uuid,
        secret_store: secrets,
        cert_cids: []
      )

    :ok = PlayerSession.input_sync(y_pid, "@name here Renamed-By-Y")
    y_out = PlayerSession.drain_buffer(y_pid)
    PlayerSession.stop(y_pid)

    # CX-93ea: denial is now ALSO visible at the verb-reply level — Y's
    # session actually printed a permission-denied line, not a silent
    # false success.
    assert Enum.any?(y_out, &String.contains?(&1, "don't have permission"))

    assert_write_denied(store, room1_meta, x_head.id)
  end

  # CX-93ea: previously the MUD verb layer (`World.set_meta/6` →
  # `Schemas.write_meta_doc/4` → `CommitStoreClient.create_chained_commit/5`)
  # never checked the commit call's return value — it always reported
  # `:ok` to its caller even when the local-write gate rejected the
  # commit. That's fixed now (see `World.set_meta/6`,
  # `Commonplace.MUD.Verbs.update_meta/4`), so the store-level check
  # below is a belt-and-suspenders assertion alongside the verb-reply
  # assertion in the test above, not a workaround for a gap.
  defp assert_write_denied(store, doc_uuid, expected_head_id) do
    assert {:ok, head} = CommitStore.latest_commit(store, doc_uuid)
    assert head.id == expected_head_id
  end

  # CX-93ea: a multi-write verb (`@dig` — genesis room doc, THEN an
  # add-entry write on root, THEN an exit-edge write on the current
  # room) denied partway through. Y holds no cert at all, so the very
  # first non-genesis write (linking the new room into root's schema)
  # is denied and `do_dig_write/4` stops there — the exit-edge write on
  # room1 never happens. The new room's own genesis commit (exempt from
  # the trust gate — see `local_write_gate_check/2`'s genesis clause)
  # DOES land, orphaned with nothing pointing at it: this module has no
  # rollback (append-only store), so that's the expected, documented
  # partial-write outcome — not a bug to fix here (same stance as
  # `Commonplace.MUD.Move`'s dest-add/source-remove ordering and
  # `WikiLive`'s create-page path, CX-qat5.3).
  test "a multi-write verb (@dig) denied partway through reports failure and leaves root untouched",
       %{store: store, root_uuid: root_uuid, secrets: secrets, y_uuid: y_uuid} do
    {:ok, root_head_before} = CommitStore.latest_commit(store, root_uuid)

    {:ok, y_pid} =
      PlayerSession.start_link(
        player_name: "y",
        root_uuid: root_uuid,
        store: store,
        buffered: true,
        player_identity_uuid: y_uuid,
        secret_store: secrets,
        cert_cids: []
      )

    :ok = PlayerSession.input_sync(y_pid, "@dig north Y's Folly")
    y_out = PlayerSession.drain_buffer(y_pid)
    PlayerSession.stop(y_pid)

    assert Enum.any?(y_out, &String.contains?(&1, "don't have permission"))
    refute Enum.any?(y_out, &String.contains?(&1, "You carve out"))

    # root's directory schema never gained the new room entry — the
    # add-entry write (the second of three) is what got denied.
    assert {:ok, root_head_after} = CommitStore.latest_commit(store, root_uuid)
    assert root_head_after.id == root_head_before.id
  end

  # CX-el97: a move DENIED by the trust gate (Y holds no cert, so the presence
  # write to the destination room is refused under enforce) must report a
  # PERMISSION denial — not a fake dead-end ("You can't go east") that masks a
  # real exit as a navigation failure. And a move onto a NON-exit must still
  # report the honest dead-end, so the player can tell the two apart.
  test "a denied move on a REAL exit reports permission, not a fake dead-end (and a non-exit still reads as a dead-end)",
       %{store: store, root_uuid: root_uuid, secrets: secrets, y_uuid: y_uuid, room2_dir: room2_dir} do
    {:ok, y_pid} =
      PlayerSession.start_link(
        player_name: "y",
        root_uuid: root_uuid,
        store: store,
        buffered: true,
        player_identity_uuid: y_uuid,
        secret_store: secrets,
        cert_cids: []
      )

    _ = PlayerSession.drain_buffer(y_pid)

    # EAST is a real exit — but Y can't write its presence into room2, so the
    # move is trust-denied. The reply must say PERMISSION, not "can't go".
    :ok = PlayerSession.input_sync(y_pid, "east")
    east_out = PlayerSession.drain_buffer(y_pid)

    assert Enum.any?(east_out, &String.contains?(&1, "permission")),
           "a trust-denied move on a real exit must report permission, got: #{inspect(east_out)}"

    refute Enum.any?(east_out, &String.contains?(&1, "can't go"))

    # Y never actually moved — the destination write was denied.
    assert :sys.get_state(y_pid).current_room_uuid != room2_dir

    # SOUTH is not an exit at all — the honest dead-end message still stands.
    :ok = PlayerSession.input_sync(y_pid, "south")
    south_out = PlayerSession.drain_buffer(y_pid)
    assert Enum.any?(south_out, &String.contains?(&1, "can't go south"))

    PlayerSession.stop(y_pid)
  end

  ## ---- low-level, root-signed world-building helpers ----

  defp genesis(store: store, uuid: uuid, schema_doc: doc, ctx: ctx) do
    update = Yelixer.Encoding.encode_update(doc)
    assert %Commonplace.Store.Commit{} = CommitStore.create_commit(store, uuid, update, nil, %{}, signing_context: ctx)
    uuid
  end

  defp new_dir(store, ctx) do
    uuid = UUID.uuid4()
    genesis(store: store, uuid: uuid, schema_doc: Schema.new_schema(), ctx: ctx)
  end

  defp new_dir_with_meta(store, ctx, filename, json) do
    meta_uuid = new_text_doc(store, ctx, json)
    doc = Schema.add_file(Schema.new_schema(), filename, meta_uuid)
    uuid = UUID.uuid4()
    genesis(store: store, uuid: uuid, schema_doc: doc, ctx: ctx)
  end

  defp new_text_doc(store, ctx, text) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "meta")
    doc = ContentType.insert_text(doc, 0, text)
    update = Yelixer.Encoding.encode_update(doc)
    assert %Commonplace.Store.Commit{} = CommitStore.create_commit(store, uuid, update, nil, %{}, signing_context: ctx)
    uuid
  end

  # CX-vhnj: a realistic presence carries `bound_identity` (Presence.create
  # stamps it from the signer). The session now reuses a `<name>.usr` only when
  # its bound_identity matches, so a signed player's pre-seeded presence must
  # carry their identity — else they'd (correctly) spawn fresh instead of reusing
  # this hand-built one.
  defp new_map_doc(store, ctx, name, type_ext, bound_identity) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new() |> ContentType.create(:map, "#{name}.#{type_ext}")
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", type_ext)
    doc = ContentType.set_key(doc, "status", "starting")
    doc = if bound_identity, do: ContentType.set_key(doc, "bound_identity", bound_identity), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    assert %Commonplace.Store.Commit{} = CommitStore.create_commit(store, uuid, update, nil, %{}, signing_context: ctx)
    uuid
  end

  defp add_directory(store, ctx, parent_uuid, name, child_uuid) do
    {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Yelixer.Encoding.encode_update(schema)

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(store, parent_uuid, update, %{}, signing_context: ctx)

    :ok
  end

  defp add_file(store, ctx, parent_uuid, name, child_uuid) do
    {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Yelixer.Encoding.encode_update(schema)

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(store, parent_uuid, update, %{}, signing_context: ctx)

    :ok
  end

  defp player_json(name), do: Jason.encode!(%{"kind" => "player", "name" => name, "title" => name, "description" => ""})

  defp room_json(name, exits),
    do: Jason.encode!(%{"kind" => "room", "name" => name, "description" => "", "exits" => exits})
end
