defmodule Commonplace.MUD.World.FacadeTest do
  @moduledoc """
  CX-ndvi §2/§6 pins 1-3, 7 — the intersection authority model:
  invoker-signed writes authorized iff (a) `Trust.authorized?(invoker,
  :write, scope)` [the EXISTING local-write gate
  (`Commonplace.Store.CommitStore`'s `local_write_gate_check/2`),
  exercised end-to-end here — the facade doesn't reimplement it, it
  just always signs as the invoker] AND (b) `scope ⊆ owner_grant`
  [checked HERE, in the facade, BEFORE any commit is even attempted].

  Setup mirrors `Commonplace.MUD.SectionOwnershipTest`'s named-store +
  strict-trust + `:enforce`-gate pattern.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_facade_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"facade_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"facade_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"facade_tss_#{n}",
       pending_imports_name: :"facade_pi_#{n}"}
    )

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

      File.rm_rf!(dir)
    end)

    {trusted_pub, trusted_priv} = Signing.generate_keypair()
    trusted_identity = "invA-#{:rand.uniform(999_999_999_999)}"

    trusted_ctx = %SigningContext{
      identity_uuid: trusted_identity,
      private_key: trusted_priv,
      public_key: trusted_pub
    }

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{trusted_identity => Signing.encode_key(trusted_pub)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    {:ok, obj_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Schemas.Object{name: "widget", description: "a thing"}),
        store,
        signing_context: trusted_ctx
      )

    {uncapped_pub, uncapped_priv} = Signing.generate_keypair()
    uncapped_identity = "invB-#{:rand.uniform(999_999_999_999)}"

    uncapped_ctx = %SigningContext{
      identity_uuid: uncapped_identity,
      private_key: uncapped_priv,
      public_key: uncapped_pub
    }

    %{store: store, obj_uuid: obj_uuid, trusted_ctx: trusted_ctx, uncapped_ctx: uncapped_ctx}
  end

  test "pin 1: invoker write-authorized + owner-grant covers → lands, signed by invoker, via_verb present", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    facade =
      Facade.new(
        %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil},
        obj_uuid,
        [obj_uuid],
        {"verbs/poke.safe.elx", "owner-x"},
        store
      )

    assert :ok = Facade.set_attr(facade, "note", "poked")

    # `set_attr` writes the object's __object.json META FILE (a child
    # doc of the object directory), not the directory schema doc itself
    # — resolve that child uuid to check the actual write.
    meta_uuid = meta_file_uuid(store, obj_uuid)
    assert {:ok, head} = CommitStore.latest_commit(store, meta_uuid)
    assert head.signer_id == Signing.signer_id(trusted_ctx.identity_uuid, trusted_ctx.public_key)
    assert head.metadata[:via_verb] == {"verbs/poke.safe.elx", "owner-x"}
  end

  defp meta_file_uuid(store, obj_uuid) do
    {:ok, schema} = Schemas.load_dir_schema(obj_uuid, store)
    {:ok, entry} = Commonplace.Tree.Schema.get_entry(schema, Schemas.object_filename())
    entry.node_id
  end

  test "pin 2: intersection denial — invoker without :write on the target is DENIED (confused-deputy/setuid case)", %{
    store: store,
    obj_uuid: obj_uuid,
    uncapped_ctx: uncapped_ctx
  } do
    facade =
      Facade.new(
        %{signing_context: uncapped_ctx, cert_cids: [], signer_id: nil},
        obj_uuid,
        [obj_uuid],
        {"verbs/poke.safe.elx", "owner-x"},
        store
      )

    assert {:error, {:trust_rejected, {:untrusted_signer, _}}} = Facade.set_attr(facade, "note", "poked")

    # Nothing landed — the meta file's head is still the setup write,
    # no via_verb tag anywhere.
    meta_uuid = meta_file_uuid(store, obj_uuid)
    assert {:ok, head} = CommitStore.latest_commit(store, meta_uuid)
    refute head.metadata[:via_verb]
  end

  test "pin 3: owner-grant narrowing — invoker COULD write directly, but the verb's grant doesn't cover this target", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    other_uuid = UUID.uuid4()

    facade =
      Facade.new(
        %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil},
        obj_uuid,
        # Grant covers a DIFFERENT uuid, not obj_uuid — monotone
        # narrowing: even though trusted_ctx is a pinned root that could
        # write obj_uuid directly, the FACADE denies before attempting
        # any commit, because the owner never attached obj_uuid to this
        # verb's grant.
        [other_uuid],
        {"verbs/poke.safe.elx", "owner-x"},
        store
      )

    assert {:error, :owner_grant_exceeded} = Facade.set_attr(facade, "note", "poked")
  end

  # ---- CX-cj3t.1.1: object lifecycle (spawn/give_to_actor/consume/
  # destroy_child), plan-blessed #5991. The keystone: STRICT INTERSECTION
  # (invoker-authority AND owner_grant) — NOT owner_grant-only — on the
  # three owner-scope primitives; give_to_actor is the invoker-own-
  # inventory exception; two-tier bounds.

  defp lc_facade(sign_ctx, object_uuid, grant, extra_ctx, store) do
    Facade.new(
      Map.merge(%{signing_context: sign_ctx, cert_cids: [], signer_id: nil}, extra_ctx),
      object_uuid,
      grant,
      {"verbs/x.safe.elx", "owner-x"},
      store
    )
  end

  defp lc_dir(store, sign_ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Schemas.Object{name: name, description: "d"}),
        store,
        signing_context: sign_ctx
      )

    uuid
  end

  defp lc_entry_names(store, dir) do
    {:ok, schema} = Schemas.load_dir_schema(dir, store)
    schema |> Commonplace.Tree.Schema.list_entries() |> Enum.map(& &1.name)
  end

  # CX-lfo3 — Facade creators now key children by an instance-unique
  # "<name>-<short-uuid>.obj", so match by display-name prefix, not an
  # exact "<name>.obj".
  defp has_item?(store, dir, name) do
    Enum.any?(lc_entry_names(store, dir), &String.starts_with?(&1, name <> "-"))
  end

  test "spawn: DEFAULT-safe — a plain object cannot spawn into the room (room not in owner_grant)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    room = lc_dir(store, trusted_ctx, "room")
    # owner_grant is the default {object}, which does NOT cover the room.
    f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{current_room_uuid: room}, store)

    assert {:error, :owner_grant_exceeded} = Facade.spawn(f, "rock")
    refute has_item?(store, room, "rock")
  end

  test "spawn: happy path — room in grant AND invoker write-authorized → lands", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    room = lc_dir(store, trusted_ctx, "room")
    f = lc_facade(trusted_ctx, obj_uuid, [room], %{current_room_uuid: room}, store)

    assert {:ok, new_uuid} = Facade.spawn(f, "rock")
    assert is_binary(new_uuid)
    assert has_item?(store, room, "rock")
  end

  test "spawn: THE KEYSTONE — owner_grant covers the room but the INVOKER can't write it → BLOCKED (not setuid)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx,
    uncapped_ctx: uncapped_ctx
  } do
    # Room dir owned by the trusted root; grant DOES cover it. A visitor
    # (uncapped_ctx) invoking the owner's verb must STILL be denied — the
    # write is signed by the visitor, and the local-write gate rejects it.
    # If this returned {:ok, _}, we'd have shipped setuid-by-accident.
    room = lc_dir(store, trusted_ctx, "room")
    f = lc_facade(uncapped_ctx, obj_uuid, [room], %{current_room_uuid: room}, store)

    assert {:error, {:trust_rejected, _}} = Facade.spawn(f, "rock")
    refute has_item?(store, room, "rock")
  end

  test "give_to_actor: happy path — writes the invoker's OWN inventory with an EMPTY owner_grant (the exception)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    # EMPTY grant: give_to_actor must NOT consult owner_grant.
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    assert {:ok, _uuid} = Facade.give_to_actor(f, "coin")
    assert has_item?(store, inv, "coin")
  end

  test "give_to_actor: still gated by INVOKER-authority (drops owner_grant, not the write gate)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx,
    uncapped_ctx: uncapped_ctx
  } do
    # The inventory dir EXISTS (created by the trusted root); the invoker
    # is the uncapped visitor, who still can't write it under :enforce.
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(uncapped_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    # uncapped can't write even its own inventory under :enforce — proves
    # give_to_actor is not a total authority bypass, only a grant bypass.
    assert {:error, {:trust_rejected, _}} = Facade.give_to_actor(f, "coin")
  end

  test "CX-lfo3: same-named mints get instance-unique keys — N creates never overwrite one entry", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    {:ok, u1} = Facade.give_to_actor(f, "coin")
    {:ok, u2} = Facade.give_to_actor(f, "coin")
    {:ok, u3} = Facade.give_to_actor(f, "coin")

    # Three DISTINCT objects and three DISTINCT entries — not one entry
    # overwritten twice (the pre-fix data-loss bug: a raider couldn't give
    # a 2nd identical coin because the "<name>.obj" key collided).
    assert u1 != u2 and u2 != u3 and u1 != u3
    coin_entries = Enum.filter(lc_entry_names(store, inv), &String.starts_with?(&1, "coin-"))
    assert length(coin_entries) == 3
  end

  test "CX-nyj9: configure_attr sets a real attribute on a JUST-MINTED object (husk -> real item)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    {:ok, sword} = Facade.give_to_actor(f, "sword")
    # Fresh mint is an inert husk...
    assert {:ok, %{description: "(no description yet)"}} = Facade.get_attr(f, sword)

    # ...configure_attr on the just-minted uuid makes it real (own-creation
    # exception: no owner_grant, uuid re-gated against the minted-set).
    assert :ok = Facade.configure_attr(f, sword, "description", "a fine steel blade")
    assert {:ok, %{description: "a fine steel blade"}} = Facade.get_attr(f, sword)
  end

  test "CX-nyj9: configure_state writes freeform state on a just-minted object", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    {:ok, sword} = Facade.give_to_actor(f, "sword")
    assert :ok = Facade.configure_state(f, sword, "damage", 5)

    assert {:ok, %{"state" => %{"damage" => 5}}} =
             Commonplace.MUD.World.get_meta_map(sword, Schemas.object_filename(), store)
  end

  test "CX-nyj9 KEYSTONE: configure_* reject a uuid NOT minted this run (uuid is not a bearer token)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    # obj_uuid (the setup widget) exists and trusted_ctx COULD write it, but
    # it was not minted THIS run — the minted-set re-gate refuses it, so a
    # known uuid alone never authorizes configuration.
    assert {:error, :not_minted_here} = Facade.configure_attr(f, obj_uuid, "description", "hijacked")
    assert {:error, :not_minted_here} = Facade.configure_state(f, obj_uuid, "damage", 99)
    assert {:error, :not_minted_here} = Facade.configure_attr(f, UUID.uuid4(), "description", "ghost")

    # And a uuid minted this run IS accepted (proving the gate is the
    # minted-set, not something incidental).
    {:ok, sword} = Facade.give_to_actor(f, "sword")
    assert :ok = Facade.configure_attr(f, sword, "description", "real")
  end

  test "CX-hbua: actor_carries? checks the invoker's OWN inventory (by name, substring, and uuid)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    refute Facade.actor_carries?(f, "key")
    {:ok, key_uuid} = Facade.give_to_actor(f, "brass key")

    assert Facade.actor_carries?(f, "brass key")
    assert Facade.actor_carries?(f, "key")
    assert Facade.actor_carries?(f, key_uuid)
    refute Facade.actor_carries?(f, "sword")

    # FOOTGUN (playtest #6074): a blank/whitespace name must FAIL CLOSED
    # even while carrying items — it must NOT match "anything held".
    refute Facade.actor_carries?(f, "")
    refute Facade.actor_carries?(f, "   ")
  end

  test "CX-hbua: actor_carries? is false (no crash) when there is no inventory", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    f = lc_facade(trusted_ctx, obj_uuid, [], %{}, store)
    refute Facade.actor_carries?(f, "anything")
  end

  test "CX-hbua/DX: configure_* accept the mint's {:ok, uuid} return directly, still re-gated", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    # Pass the {:ok, uuid} tuple straight through — no manual destructuring.
    assert :ok = Facade.configure_attr(f, Facade.give_to_actor(f, "gem"), "description", "a ruby")
    # The minted-set re-gate survives the coercion: a non-minted {:ok, uuid}
    # is still refused.
    assert {:error, :not_minted_here} = Facade.configure_attr(f, {:ok, obj_uuid}, "description", "hax")
  end

  test "CX-cj3t.9: move_self moves the invoker's presence with an EMPTY grant (presence-self, NOT room-write)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    # move_self routes through World.move, which serializes via the Green
    # Bursar (same as the builtin go/take) — start one under its default name.
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      p -> GenServer.stop(p)
    end

    {:ok, bursar} =
      Commonplace.Green.Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)

    on_exit(fn -> if Process.alive?(bursar), do: GenServer.stop(bursar) end)

    room = lc_dir(store, trusted_ctx, "room")
    dest = lc_dir(store, trusted_ctx, "dest")
    player_uuid = UUID.uuid4()
    pfile = "alice.usr"

    # Place the invoker's .usr presence in `room`.
    {:ok, schema} = Schemas.load_dir_schema(room, store)
    schema = Commonplace.Tree.Schema.add_directory(schema, pfile, player_uuid)

    {meta, opts} =
      Commonplace.MUD.SignedWrite.opts_for(room,
        store: store,
        signing_context: trusted_ctx,
        cert_cids: [],
        signer_id: nil,
        via_verb: nil
      )

    Commonplace.Store.CommitStoreClient.create_chained_commit(
      store,
      room,
      Yelixer.Encoding.encode_update(schema),
      meta,
      opts
    )

    # EMPTY grant: move_self must NOT owner_grant-check (it's presence-self,
    # never write_guarded) — this is the whole point of the split.
    f =
      lc_facade(
        trusted_ctx,
        obj_uuid,
        [],
        %{current_room_uuid: room, player_uuid: player_uuid, presence_filename: pfile},
        store
      )

    assert :ok = Facade.move_self(f, dest)
    refute pfile in lc_entry_names(store, room)
    assert pfile in lc_entry_names(store, dest)
  end

  test "CX-v6j4: a ROOM-host verb persists state (bind) but is DENIED the object-only methods (setuid guard)", %{
    store: store,
    trusted_ctx: trusted_ctx
  } do
    # CX-v6j4 — a REAL room (room_filename meta = __room.json), NOT an
    # object-meta dir; the bug was writing state to __object.json which a
    # room lacks. Build the room via its room meta.
    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Commonplace.MUD.Schemas.Room{name: "room", description: "d"}),
        store,
        signing_context: trusted_ctx
      )

    # A room-hosted verb: object_uuid = the room, host_kind = :room.
    f = %{
      lc_facade(trusted_ctx, room, [room], %{current_room_uuid: room, inventory_uuid: "inv"}, store)
      | host_kind: :room
    }

    # THE FIX: state persists ACROSS CALLS on the room — write with one
    # facade, read back with a FRESH one (the real dispatch scenario, and
    # exactly what the object-meta test missed).
    assert :ok = Facade.put_state(f, "lit", true)

    f_fresh = %{
      lc_facade(trusted_ctx, room, [room], %{current_room_uuid: room, inventory_uuid: "inv"}, store)
      | host_kind: :room
    }

    assert Facade.get_state(f_fresh, "lit") == true
    assert :ok = Facade.set_attr(f, "note", "hi")
    assert {:ok, _} = Facade.create_child(f, "torch")

    # THE RESTRICTION: object-only methods are refused on a room host —
    # a room's children are shared/mixed-ownership, and destroy_child/consume
    # guard only the parent (cross-owner setuid, deferred).
    assert {:error, :requires_object_host} = Facade.consume(f)
    assert {:error, :requires_object_host} = Facade.destroy_child(f, "torch")
    assert {:error, :requires_object_host} = Facade.move_object(f, lc_dir(store, trusted_ctx, "dest"))
  end

  test "CX-cj3t.9: move_object STILL grant-checks (empty grant → :owner_grant_exceeded — the intersection is intact)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    room = lc_dir(store, trusted_ctx, "room")
    dest = lc_dir(store, trusted_ctx, "dest")

    # EMPTY grant + bound object: move_object write_guards [object, room,
    # dest], so an empty grant denies BEFORE any write — proving move_object
    # (unlike move_self) stays a room-write intersection.
    f = lc_facade(trusted_ctx, obj_uuid, [], %{current_room_uuid: room}, store)
    assert {:error, :owner_grant_exceeded} = Facade.move_object(f, dest)
  end

  test "destroy_child: happy path — create then unlink a named child of the bound object", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)

    assert {:ok, _} = Facade.create_child(f, "gear")
    assert has_item?(store, obj_uuid, "gear")

    assert :ok = Facade.destroy_child(f, "gear")
    refute has_item?(store, obj_uuid, "gear")
  end

  test "destroy_child: unknown name → :not_found (fail-visible, never a silent no-op)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
    assert {:error, :not_found} = Facade.destroy_child(f, "ghost")
  end

  test "consume: invoker-own-inventory — consume a CARRIED object with EMPTY owner_grant", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    giver = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)
    {:ok, item_uuid} = Facade.give_to_actor(giver, "potion")
    assert has_item?(store, inv, "potion")

    # Bind the verb to the carried item; EMPTY grant. locate_parent finds
    # it in the invoker's inventory → invoker-own exception → unlink.
    consumer = lc_facade(trusted_ctx, item_uuid, [], %{inventory_uuid: inv}, store)
    assert :ok = Facade.consume(consumer)
    refute has_item?(store, inv, "potion")
  end

  test "consume: room-fixed object needs INTERSECTION — EMPTY grant → :owner_grant_exceeded", %{
    store: store,
    trusted_ctx: trusted_ctx
  } do
    room = lc_dir(store, trusted_ctx, "room")
    inv = lc_dir(store, trusted_ctx, "inv")
    item = lc_dir(store, trusted_ctx, "lever")
    # Link the item into the ROOM (not inventory).
    {:ok, schema} = Schemas.load_dir_schema(room, store)
    schema = Commonplace.Tree.Schema.add_directory(schema, "lever.obj", item)

    {meta, opts} =
      Commonplace.MUD.SignedWrite.opts_for(room,
        store: store,
        signing_context: trusted_ctx,
        cert_cids: [],
        signer_id: nil,
        via_verb: nil
      )

    Commonplace.Store.CommitStoreClient.create_chained_commit(
      store,
      room,
      Yelixer.Encoding.encode_update(schema),
      meta,
      opts
    )

    # Bound to the room-fixed item, EMPTY grant, inventory doesn't hold it
    # → locate_parent falls through to the room → intersection → grant
    # doesn't cover the room → denied before any write.
    f = lc_facade(trusted_ctx, item, [], %{inventory_uuid: inv, current_room_uuid: room}, store)
    assert {:error, :owner_grant_exceeded} = Facade.consume(f)
    assert "lever.obj" in lc_entry_names(store, room)
  end

  test "orphan check (plan #5993): a gate-rejected spawn lands NO doc — rejection is at the first write", %{
    store: store,
    uncapped_ctx: uncapped_ctx
  } do
    # create_object_in creates the object's meta doc FIRST (create_meta_doc
    # → a signed, NON-genesis commit), then the dir doc, then links. Under
    # :enforce an unauthorized invoker is rejected at that FIRST write, so
    # the with-chain short-circuits before any doc is committed — no orphan
    # meta/dir doc, not just no link. Prove it directly on the primitive
    # `spawn` uses: create-then-link is atomic-or-nothing because the very
    # first sub-write is the one the gate refuses.
    assert {:error, {:trust_rejected, _}} =
             Schemas.create_dir_with_meta(
               Schemas.object_filename(),
               Schemas.encode_object(%Schemas.Object{name: "orphan", description: "d"}),
               store,
               signing_context: uncapped_ctx
             )
  end

  test "bounds: per-container cap (M=128) → :container_full, fail-visible", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    box = lc_dir(store, trusted_ctx, "box")
    # The dir already holds its meta entry (1); pad to exactly 128.
    {:ok, schema} = Schemas.load_dir_schema(box, store)

    schema =
      Enum.reduce(1..127, schema, fn i, s ->
        Commonplace.Tree.Schema.add_directory(s, "pad#{i}.obj", UUID.uuid4())
      end)

    {meta, opts} =
      Commonplace.MUD.SignedWrite.opts_for(box,
        store: store,
        signing_context: trusted_ctx,
        cert_cids: [],
        signer_id: nil,
        via_verb: nil
      )

    Commonplace.Store.CommitStoreClient.create_chained_commit(
      store,
      box,
      Yelixer.Encoding.encode_update(schema),
      meta,
      opts
    )

    assert length(lc_entry_names(store, box)) == 128

    f = lc_facade(trusted_ctx, obj_uuid, [box], %{current_room_uuid: box}, store)
    assert {:error, :container_full} = Facade.spawn(f, "overflow")
  end

  test "bounds: per-invocation op cap (N=8) → :spawn_limit on the 9th op", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    # The counter lives in THIS process's dictionary (no spawn_monitor
    # child in a unit test); ExUnit gives each test its own process, so
    # it starts at 0. 8 succeed, the 9th is charged over budget.
    for _ <- 1..8, do: assert({:ok, _} = Facade.give_to_actor(f, "coin"))
    assert {:error, :spawn_limit} = Facade.give_to_actor(f, "coin")
  end

  test "pin 7: no effect surface leak — the facade is the only capability-bearing value; it exposes no raw store accessor" do
    facade = Facade.new(%{}, "obj", [], nil, :some_store)

    assert %Facade{} = facade
    # The struct's public fields are data (store handle, ctx, grant,
    # audit tag) needed for the facade's OWN internal ops — but nothing
    # in this module's public API returns a bare `CommitStoreClient`/
    # store reference to the CALLER; every public function is one of
    # the nine locked read/write/broadcast methods. See
    # `Commonplace.MUD.SafeVerbTest` "no_leaked_bindings" for the
    # complementary compile-time proof that a safe-verb BODY has no
    # `store`/`ctx` variable in scope at all — only `world` (this
    # facade value) and `args`.
    refute function_exported?(Facade, :store, 1)
    refute function_exported?(Facade, :raw_store, 1)
  end

  # ---- P0 KEY-LEAK regression (data-reachability axis, plan #6107) ----
  # A verb holds the %Facade{}, and the allowlist permits inspect/1 +
  # world.<field> reads, so ANY signing material in the struct's object
  # graph leaks. These pin that the VERB-FACING facade carries none.

  describe "P0: signing material is not verb-reachable" do
    setup %{store: store, trusted_ctx: trusted_ctx, obj_uuid: obj_uuid} do
      facade =
        Facade.new(
          %{
            signing_context: trusted_ctx,
            cert_cids: [],
            signer_id: nil,
            player_name: "alice",
            current_room_uuid: "room1",
            inventory_uuid: "inv1",
            player_uuid: "p1"
          },
          obj_uuid,
          [obj_uuid],
          {"verbs/x.safe.elx", "owner"},
          store
        )

      %{facade: facade}
    end

    test "PIN 1: scrub_signer removes all signing material; inspect(world) surfaces no key bytes", %{
      facade: facade,
      trusted_ctx: trusted_ctx
    } do
      scrubbed = Facade.scrub_signer(facade)

      # The scrubbed ctx (what the verb sees) carries no signing material.
      assert Map.get(scrubbed.ctx, :signing_context) == nil
      assert Map.get(scrubbed.ctx, :cert_cids) == nil
      assert Map.get(scrubbed.ctx, :signer_id) == nil

      # inspect(world) AND world.ctx.* surface no private-key bytes.
      key_bytes = inspect(trusted_ctx.private_key)
      refute String.contains?(inspect(scrubbed, limit: :infinity), key_bytes)
      refute String.contains?(inspect(scrubbed.ctx, limit: :infinity), key_bytes)

      # Opaque Inspect render (belt) shows only the non-secret player name.
      assert inspect(scrubbed) == "#MUD.World.Facade<player: alice>"

      # Post-scrub remainder is all non-secret (identity + location + provenance).
      assert scrubbed.ctx == %{player_name: "alice", current_room_uuid: "room1", inventory_uuid: "inv1", player_uuid: "p1"}
    end

    test "PIN 2: the verb-facing facade (via the real SafeVerb.run path) exposes no key; signing still works", %{
      store: store,
      trusted_ctx: trusted_ctx,
      obj_uuid: obj_uuid,
      facade: facade
    } do
      # A hostile verb tries to exfil: return inspect of world AND world.ctx.
      :ok =
        Commonplace.MUD.VerbSource.save_safe_verb(
          obj_uuid,
          "exfil",
          ~s|inspect({world, world.ctx})|,
          [obj_uuid],
          store,
          signing_context: trusted_ctx
        )

      {:ok, rendered} =
        Commonplace.MUD.VerbSource.run_safe_verb(obj_uuid, "exfil", [obj_uuid], facade, %{}, store)

      # The verb ran with the SCRUBBED facade — no key bytes anywhere in what
      # it could see/render.
      refute String.contains?(rendered, inspect(trusted_ctx.private_key))
      refute rendered =~ "signing_context"

      # And write_opts still recovers the signer (process-dict path) so a
      # facade WRITE from a verb still signs — prove set_attr lands.
      :ok =
        Commonplace.MUD.VerbSource.save_safe_verb(
          obj_uuid,
          "poke",
          ~s|Commonplace.MUD.World.Facade.set_attr(world, "note", "hi")|,
          [obj_uuid],
          store,
          signing_context: trusted_ctx
        )

      assert {:ok, :ok} =
               Commonplace.MUD.VerbSource.run_safe_verb(obj_uuid, "poke", [obj_uuid], facade, %{}, store)
    end

    test "PIN 3: a representative RETURN value (get_attr) carries no signing material", %{facade: facade} do
      # get_attr returns object metadata — assert it never carries a signer.
      case Facade.get_attr(facade, facade.object_uuid) do
        {:ok, attrs} ->
          refute Map.has_key?(attrs, :signing_context)
          refute Map.has_key?(attrs, :private_key)

        {:error, _} ->
          :ok
      end
    end
  end
end
