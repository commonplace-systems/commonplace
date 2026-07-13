defmodule Commonplace.MUD.RoomVisibilityTest do
  @moduledoc """
  CX-ivqz (read-scoping P2) — the PLUMBING slice: `owner`/`visibility`
  fields on `Commonplace.MUD.Schemas.Room`, the private-by-default
  citizenship mint, the `World.room_snapshot/4` read gate, and the
  `@private`/`@public` builder verbs.

  Covers the build-brief's Z1/Z2/Z3/Z7 deltas at the plumbing layer (the
  trust-core verifier itself, `Commonplace.Trust.Read`, is UNCHANGED and
  already covered by `Commonplace.Trust.ReadTest`).

  ## Trust-config note

  `Commonplace.Trust.Read.authorized?/3`'s gated branch consults
  `Commonplace.Trust.reader_authorized?/6`, which short-circuits to
  `true` whenever `cfg.accept_unsigned` (the DEFAULT, zero-config
  posture — see `Commonplace.Trust.config/0`'s moduledoc). So any test
  that wants to observe an actual READ denial must pin a strict trust
  config (`accept_unsigned: false`), exactly like
  `Commonplace.Trust.ReadTest`'s setup — independent of
  `:local_write_gate` (a SEPARATE knob that only gates the WRITE path).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.Parser
  alias Commonplace.MUD.{Citizenship, PlayerSession, Schemas, Verbs, World}
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  # ---- encode/decode round-trip (no store needed) ----

  describe "Room encode/decode" do
    test "owner + visibility survive a round-trip" do
      r = %Room{
        name: "The Vault",
        description: "A locked room.",
        owner: "owner-uuid-1",
        visibility: :capability_gated
      }

      assert {:ok, decoded} = r |> Schemas.encode_room() |> Schemas.decode_room()
      assert decoded == r
    end

    test "ABSENT fields decode to :public / nil (no-regression default)" do
      json = ~s({"kind":"room","name":"x","description":"y"})
      assert {:ok, %Room{owner: nil, visibility: :public}} = Schemas.decode_room(json)
    end

    test "an unknown visibility string decodes to :public (never crashes on garbage)" do
      json = ~s({"kind":"room","name":"x","description":"y","visibility":"top-secret"})
      assert {:ok, %Room{visibility: :public}} = Schemas.decode_room(json)
    end

    test "a room encoded with DEFAULTS carries NO owner/visibility keys (byte-stability guard)" do
      json = Schemas.encode_room(%Room{name: "Plain Room", description: "Nothing special."})
      {:ok, decoded} = Jason.decode(json)

      refute Map.has_key?(decoded, "owner")
      refute Map.has_key?(decoded, "visibility")
    end

    test "a room with only owner set (still public) omits the visibility key but keeps owner" do
      json = Schemas.encode_room(%Room{name: "x", description: "y", owner: "some-owner"})
      {:ok, decoded} = Jason.decode(json)

      assert decoded["owner"] == "some-owner"
      refute Map.has_key?(decoded, "visibility")
    end
  end

  # ---- shared strict-trust setup (accept_unsigned: false) ----
  # Bare CommitStore (no TrustSideStore) suffices here — the gated
  # non-owner branch only reaches `cert_grants_read?/5` (which needs a
  # cap store) when `cert_cids` is non-empty; every test below presents
  # none, so the plain owner-vs-not comparison + trusted_identities check
  # is all that's exercised.
  defp with_strict_trust(dir) do
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
    end)

    :ok
  end

  # ---- World.room_snapshot/4 gate ----

  describe "World.room_snapshot/4 gate" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_room_vis_world_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      store = :"room_vis_world_store_#{:rand.uniform(1_000_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store})
      on_exit(fn -> File.rm_rf!(dir) end)
      with_strict_trust(dir)
      %{store: store}
    end

    defp mint_room(store, room) do
      {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), Schemas.encode_room(room), store)
      dir_uuid
    end

    test "NO-REGRESSION: a public room (no fields) snapshots identically for any viewer incl. nil",
         %{store: store} do
      room = %Room{name: "Commons", description: "Open to all.", exits: %{"north" => "somewhere"}}
      room_uuid = mint_room(store, room)

      assert {:ok, snap_nil} = World.room_snapshot(room_uuid, "self.usr", store)
      assert {:ok, snap_explicit_nil} = World.room_snapshot(room_uuid, "self.usr", store, viewer: nil)
      assert {:ok, snap_stranger} = World.room_snapshot(room_uuid, "self.usr", store, viewer: "anyone-at-all")

      assert snap_nil == snap_explicit_nil
      assert snap_nil == snap_stranger
      assert snap_nil.name == "Commons"
    end

    test "Z1/Z2: a capability_gated room refuses everyone but the owner, with NO partial data",
         %{store: store} do
      room = %Room{
        name: "Alice's Den",
        description: "Private quarters.",
        owner: "alice-id",
        visibility: :capability_gated
      }

      room_uuid = mint_room(store, room)

      assert {:ok, %{name: "Alice's Den"}} = World.room_snapshot(room_uuid, "self.usr", store, viewer: "alice-id")

      assert {:error, :read_denied} = World.room_snapshot(room_uuid, "self.usr", store, viewer: "bob-id")
      assert {:error, :read_denied} = World.room_snapshot(room_uuid, "self.usr", store, viewer: nil)
      assert {:error, :read_denied} = World.room_snapshot(room_uuid, "self.usr", store)
    end
  end

  # ---- Citizenship mint (enforce mode — proves the write is genuinely node-signed) ----

  describe "Citizenship.ensure/5 mint" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_room_vis_cit_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      n = :rand.uniform(1_000_000_000)
      store = :"room_vis_cit_store_#{n}"

      start_supervised!(
        {Commonplace.Store.Supervisor,
         data_dir: dir,
         name: :"room_vis_cit_sup_#{n}",
         commit_store_name: store,
         trust_side_store_name: :"room_vis_cit_tss_#{n}",
         pending_imports_name: :"room_vis_cit_pi_#{n}"}
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

      {:ok, node_ctx} = NodeIdentity.signing_context()
      root_uuid = UUID.uuid4()
      update = Encoding.encode_update(Schema.new_schema())

      assert %Commonplace.Store.Commit{} =
               CommitStore.create_commit(store, root_uuid, update, nil, %{}, signing_context: node_ctx)

      {pub, _priv} = Signing.generate_keypair()
      identity_uuid = UUID.uuid4()

      %{store: store, root: root_uuid, identity_uuid: identity_uuid, pub: pub}
    end

    test "a fresh home's room doc carries owner=<identity> + capability_gated",
         %{store: store, root: root, identity_uuid: identity_uuid, pub: pub} do
      assert {:ok, %{home_room_uuid: home_uuid}} = Citizenship.ensure(identity_uuid, pub, "arwen", root, store)

      assert {:ok, %Room{owner: ^identity_uuid, visibility: :capability_gated}} =
               Schemas.load_room(home_uuid, store)
    end
  end

  # ---- @private / @public verbs (direct Verbs.dispatch — permissive store) ----

  describe "@private / @public verbs (permissive)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_room_vis_verb_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      store = :"room_vis_verb_store_#{:rand.uniform(1_000_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store})
      on_exit(fn -> File.rm_rf!(dir) end)

      room = %Room{name: "Some Room", description: "A plain room."}
      {:ok, room_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), Schemas.encode_room(room), store)

      %{store: store, room_uuid: room_uuid}
    end

    defp fresh_signing_context do
      {pub, priv} = Signing.generate_keypair()
      %SigningContext{identity_uuid: UUID.uuid4(), public_key: pub, private_key: priv}
    end

    defp verb_ctx(room_uuid, store, signing_context) do
      %{
        current_room_uuid: room_uuid,
        store: store,
        signing_context: signing_context,
        cert_cids: [],
        signer_id: nil
      }
    end

    test "@private flips the current room (owner-signed) and @public flips back", %{
      store: store,
      room_uuid: room_uuid
    } do
      owner_ctx = fresh_signing_context()
      ctx = verb_ctx(room_uuid, store, owner_ctx)

      assert {:reply, "This place is now private."} =
               Verbs.dispatch(%Parser.Command{verb: "@private"}, ctx)

      assert {:ok, %Room{visibility: :capability_gated, owner: owner_id}} = Schemas.load_room(room_uuid, store)
      assert owner_id == owner_ctx.identity_uuid

      assert {:reply, "This place is now public."} =
               Verbs.dispatch(%Parser.Command{verb: "@public"}, ctx)

      assert {:ok, %Room{visibility: :public, owner: ^owner_id}} = Schemas.load_room(room_uuid, store)
    end
  end

  # ---- look through PlayerSession renders "That place is private." ----

  describe "look on a gated room, via PlayerSession" do
    setup do
      Application.ensure_all_started(:phoenix_pubsub)

      case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      dir = Path.join(System.tmp_dir!(), "cp_room_vis_look_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      store = :"room_vis_look_store_#{:rand.uniform(1_000_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store})
      on_exit(fn -> File.rm_rf!(dir) end)

      case GenServer.whereis(Commonplace.Green.Bursar) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      root_uuid = UUID.uuid4()

      {:ok, bursar_pid} =
        Commonplace.Green.Bursar.start_link(root_uuid: root_uuid, store: store, sweep_interval: 60_000)

      on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

      update = Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(store, root_uuid, update, nil)

      # NOTE: local_write_gate stays at the default (:dry_run) — writes
      # still land under strict trust (dry_run only LOGS a would-deny),
      # so PlayerSession's own unsigned/uncertified bootstrap writes
      # (player dirs, presence, inventory) are unaffected. Only the READ
      # gate (`Read.authorized?`, consulted directly by
      # `World.room_snapshot/4`, never through `local_write_gate`) needs
      # the strict config to actually observe a denial.
      with_strict_trust(dir)

      owner_ctx = fresh_signing_context_look()
      {:ok, owner_room_uuid} =
        Schemas.create_dir_with_meta(
          Schemas.room_filename(),
          Schemas.encode_room(%Room{
            name: "Owner's Den",
            description: "Cozy and private.",
            owner: owner_ctx.identity_uuid,
            visibility: :capability_gated
          }),
          store
        )

      %{store: store, root: root_uuid, owner_ctx: owner_ctx, private_room_uuid: owner_room_uuid}
    end

    defp fresh_signing_context_look do
      {pub, priv} = Signing.generate_keypair()
      %SigningContext{identity_uuid: UUID.uuid4(), public_key: pub, private_key: priv}
    end

    defp start_look_player(name, ctx, opts) do
      parent = self()
      output_fn = fn text -> send(parent, {:out, name, text}) end

      {:ok, session} =
        PlayerSession.start_link(
          Keyword.merge(
            [player_name: name, root_uuid: ctx.root, store: ctx.store, output_fn: output_fn, owner_pid: parent],
            opts
          )
        )

      drain_look(name)
      session
    end

    defp drain_look(name, acc \\ []) do
      receive do
        {:out, ^name, text} -> drain_look(name, [text | acc])
      after
        30 -> Enum.reverse(acc)
      end
    end

    defp send_input_look(session, text) do
      PlayerSession.input_sync(session, text)
      Process.sleep(50)
    end

    test "a stranger is refused ENTRY to the gated room (CX-avzp) — denied at the door, no leak", ctx do
      stranger_ctx = fresh_signing_context_look()

      stranger =
        start_look_player("stranger", ctx, signing_context: stranger_ctx)

      # CX-avzp — the private-room denial now fires ATOMICALLY at the MOVE
      # (@teleport routes through `World.move_presence`), not merely in the
      # later `look` render: the stranger never enters, so the presence +
      # eavesdrop leak is closed at the door. (The render gate itself — a
      # viewer standing in a room they can't read — is covered directly by the
      # `World.room_snapshot/4 gate` unit block above.)
      send_input_look(stranger, "@teleport #{ctx.private_room_uuid}")
      out = drain_look("stranger") |> Enum.join("\n")

      assert out =~ "That place is private."
      refute out =~ "Owner's Den"
      refute out =~ "Cozy and private."
    end

    test "the owner's own look on their gated room renders normally (self-read)", ctx do
      owner = start_look_player("owner", ctx, signing_context: ctx.owner_ctx, spawn_room_uuid: ctx.private_room_uuid)

      send_input_look(owner, "look")
      out = drain_look("owner") |> Enum.join("\n")

      assert out =~ "Owner's Den"
    end
  end

  # ---- non-owner write REFUSED under enforce (direct Verbs.dispatch) ----

  describe "@private is REFUSED for a non-owner under enforce" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_room_vis_enforce_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      n = :rand.uniform(1_000_000_000)
      store = :"room_vis_enforce_store_#{n}"

      start_supervised!(
        {Commonplace.Store.Supervisor,
         data_dir: dir,
         name: :"room_vis_enforce_sup_#{n}",
         commit_store_name: store,
         trust_side_store_name: :"room_vis_enforce_tss_#{n}",
         pending_imports_name: :"room_vis_enforce_pi_#{n}"}
      )

      # CX-6hxa: restore under the REAL app-env key names, one at a time
      # — a shorthand map-key restore loop across
      # (data_dir/trust/local_write_gate) leaked env across files before;
      # keep each key explicit here.
      old_data_dir = Application.get_env(:commonplace, :data_dir)
      old_trust = Application.get_env(:commonplace, :trust)
      old_knob = Application.get_env(:commonplace, :local_write_gate)

      Application.put_env(:commonplace, :data_dir, dir)

      {pub_a, priv_a} = Signing.generate_keypair()
      identity_a = UUID.uuid4()
      a_ctx = %SigningContext{identity_uuid: identity_a, public_key: pub_a, private_key: priv_a}

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{identity_a => Signing.encode_key(pub_a)}
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

      root_uuid = UUID.uuid4()
      update = Encoding.encode_update(Schema.new_schema())

      assert %Commonplace.Store.Commit{} =
               CommitStore.create_commit(store, root_uuid, update, nil, %{}, signing_context: a_ctx)

      # A's OWNED home, minted via Citizenship so A genuinely holds the
      # {:docs, [meta_uuid]} :write cap the trust gate checks.
      assert {:ok, %{home_room_uuid: home_uuid, cert_cids: a_cids}} =
               Citizenship.ensure(identity_a, pub_a, "alice", root_uuid, store)

      {pub_b, priv_b} = Signing.generate_keypair()
      identity_b = UUID.uuid4()
      b_ctx = %SigningContext{identity_uuid: identity_b, public_key: pub_b, private_key: priv_b}

      %{store: store, root: root_uuid, home_uuid: home_uuid, a_ctx: a_ctx, a_cids: a_cids, b_ctx: b_ctx}
    end

    test "a non-owner's @private on A's home is REFUSED (write denied -> verb error)", ctx do
      # B is signed (strict trust requires SOME signature to even reach
      # the cert check) but holds NO cert over A's home meta doc, and is
      # not the pinned/trusted identity — so B's write is denied by the
      # SAME `local_write_gate: :enforce` path `@desc` is denied by.
      b_verb_ctx = %{
        current_room_uuid: ctx.home_uuid,
        store: ctx.store,
        signing_context: ctx.b_ctx,
        cert_cids: [],
        signer_id: nil
      }

      assert {:error, "You don't own this place."} =
               Verbs.dispatch(%Parser.Command{verb: "@private"}, b_verb_ctx)

      # The room's visibility is UNCHANGED — B's write never landed.
      assert {:ok, %Room{visibility: :capability_gated, owner: owner_id}} =
               Schemas.load_room(ctx.home_uuid, ctx.store)

      assert owner_id == ctx.a_ctx.identity_uuid
    end

    test "the OWNER's @private on their own home LANDS under the same enforce gate", ctx do
      a_verb_ctx = %{
        current_room_uuid: ctx.home_uuid,
        store: ctx.store,
        signing_context: ctx.a_ctx,
        cert_cids: ctx.a_cids,
        signer_id: nil
      }

      # A's room is already capability_gated (Citizenship mints private
      # by default) — flip to :public first so this exercises A's OWN
      # write actually landing (not a no-op).
      assert {:reply, "This place is now public."} =
               Verbs.dispatch(%Parser.Command{verb: "@public"}, a_verb_ctx)

      assert {:ok, %Room{visibility: :public}} = Schemas.load_room(ctx.home_uuid, ctx.store)
    end
  end
end
