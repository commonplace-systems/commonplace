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
  import ExUnit.CaptureLog

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStore
  alias Yelixer.Encoding

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

    assert {:error, :refused} = Facade.set_attr(facade, "note", "poked")

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

    assert {:error, :refused} = Facade.set_attr(facade, "note", "poked")
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

    assert {:error, :refused} = Facade.spawn(f, "rock")
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

    assert {:error, :refused} = Facade.spawn(f, "rock")
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
    assert {:error, :refused} = Facade.give_to_actor(f, "coin")
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
    assert {:error, :refused} = Facade.configure_attr(f, obj_uuid, "description", "hijacked")
    assert {:error, :refused} = Facade.configure_state(f, obj_uuid, "damage", 99)
    assert {:error, :refused} = Facade.configure_attr(f, UUID.uuid4(), "description", "ghost")

    # And a uuid minted this run IS accepted (proving the gate is the
    # minted-set, not something incidental).
    {:ok, sword} = Facade.give_to_actor(f, "sword")
    assert :ok = Facade.configure_attr(f, sword, "description", "real")
  end

  test "CX-ssi6: configure_attr/configure_state with a mistyped arg → {:error, :bad_arg}, NOT a function-clause crash", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)

    # A non-binary KEY (the agent's real bug — passed an integer where a
    # string key was needed) previously FunctionClauseError-crashed; now it's
    # a clean {:error, :bad_arg} (surfaced as a dim author-diagnostic via the
    # CX-3x5a accumulator, not a runtime_error crash).
    assert {:error, :bad_arg} = Facade.configure_attr(f, "some-uuid", 123, "v")
    assert {:error, :bad_arg} = Facade.configure_state(f, "some-uuid", 123, "v")
    # A minted ref that's neither {:ok, uuid} nor a bare uuid string.
    assert {:error, :bad_arg} = Facade.configure_attr(f, :not_a_uuid, "k", "v")
    assert {:error, :bad_arg} = Facade.configure_state(f, {:error, :nope}, "k", "v")
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
    assert {:error, :refused} = Facade.configure_attr(f, {:ok, obj_uuid}, "description", "hax")
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
    assert {:error, :refused} = Facade.consume(f)
    assert {:error, :refused} = Facade.destroy_child(f, "torch")
    assert {:error, :refused} = Facade.move_object(f, lc_dir(store, trusted_ctx, "dest"))
  end

  test "CX-gs9e REPRO: two sequential put_state calls in one verb run BOTH persist (no read-after-write clobber)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    # The suspected bug: within ONE verb run, put_state(a) chains a commit,
    # then put_state(b)'s read_state re-reads the meta — if that read is
    # STALE (doesn't see the a-commit), new_state = %{b} drops a. Reproduce
    # with two sequential writes on the SAME facade, then read both back via
    # a FRESH facade (the real cross-call read path).
    f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)

    assert :ok = Facade.put_state(f, "a", 1)
    assert :ok = Facade.put_state(f, "b", 2)

    f_fresh = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
    assert Facade.get_state(f_fresh, "a") == 1, "first write clobbered by second (read-after-write stale)"
    assert Facade.get_state(f_fresh, "b") == 2
  end

  describe "CX-qexv: structured state values (plan #6163)" do
    test "a LIST value persists and round-trips via a fresh facade", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      assert :ok = Facade.put_state(f, "chord", ["c", "e", "g"])

      f_fresh = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      assert Facade.get_state(f_fresh, "chord") == ["c", "e", "g"]
    end

    test "a string-keyed MAP persists and round-trips with STRING keys (gotcha #3 pin)", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      assert :ok = Facade.put_state(f, "prog", %{"secret" => "rose", "step" => 2})

      f_fresh = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      got = Facade.get_state(f_fresh, "prog")
      assert got == %{"secret" => "rose", "step" => 2}
      # Keys come back as STRINGS (Jason.decode default), NOT atoms — the
      # atom-table-exhaustion guard the plan flagged. Assert the invariant
      # directly, don't rely on it incidentally.
      assert Enum.all?(Map.keys(got), &is_binary/1)
    end

    test "nested list-of-maps round-trips (real puzzle shape)", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      val = [%{"pos" => 1, "on" => true}, %{"pos" => 2, "on" => false}]
      assert :ok = Facade.put_state(f, "dials", val)

      f_fresh = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      assert Facade.get_state(f_fresh, "dials") == val
    end

    test "HOSTILE non-JSON inputs are rejected CLEANLY (validator never raises — gotcha #1)", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)

      # Each of these reaches validate_state_value; the shape-first ordering
      # (or non-raising encode) means we get a clean {:error, :state_bounds},
      # NOT a Jason.encode! raise inside the validator.
      assert {:error, :too_large} = Facade.put_state(f, "k", {:a, :b})
      assert {:error, :too_large} = Facade.put_state(f, "k", :some_atom)
      assert {:error, :too_large} = Facade.put_state(f, "k", [1, {:nested, :tuple}])
      assert {:error, :too_large} = Facade.put_state(f, "k", %{"ok" => :atom_value})
      assert {:error, :too_large} = Facade.put_state(f, "k", %{atom_key: 1})
      assert {:error, :too_large} = Facade.put_state(f, "k", %{"nested" => {:t}})

      # And nothing hostile persisted.
      f_fresh = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      assert Facade.get_state(f_fresh, "k") == nil
    end

    test "over-1024-byte structured value → :state_bounds (identical ceiling)", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      big = List.duplicate("xxxxxxxx", 200)
      assert {:error, :too_large} = Facade.put_state(f, "k", big)
    end

    test "nesting deeper than @state_max_depth → :state_bounds", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      # 12 levels of list nesting, well past the depth 8 bound.
      deep = Enum.reduce(1..12, 0, fn _, acc -> [acc] end)
      assert {:error, :too_large} = Facade.put_state(f, "k", deep)
    end
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
    assert {:error, :refused} = Facade.move_object(f, dest)
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
    assert {:error, :refused} = Facade.consume(f)
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
    assert {:error, :full} = Facade.spawn(f, "overflow")
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
    assert {:error, :refused} = Facade.give_to_actor(f, "coin")
  end

  # ---- CX-5u5j: own-inventory quest/gift verbs (plan-blessed #6171) ----
  # consume_from_inventory (own-inventory authority, distinct from consume/1)
  # and give_from_inventory (same-room recipient mailbox, no-global-oracle
  # ordering + additive-only deposit + server-stamped narration).

  # Link a set of object entries directly into `dir` under one signed commit
  # (no lifecycle-op charge), for seeding inventories without touching N=8.
  defp seed_entries(store, sign_ctx, dir, names) do
    {:ok, schema} = Schemas.load_dir_schema(dir, store)

    schema =
      Enum.reduce(names, schema, fn name, s ->
        Commonplace.Tree.Schema.add_directory(s, name, UUID.uuid4())
      end)

    {meta, opts} =
      Commonplace.MUD.SignedWrite.opts_for(dir,
        store: store,
        signing_context: sign_ctx,
        cert_cids: [],
        signer_id: nil,
        via_verb: nil
      )

    Commonplace.Store.CommitStoreClient.create_chained_commit(
      store,
      dir,
      Yelixer.Encoding.encode_update(schema),
      meta,
      opts
    )

    :ok
  end

  test "consume_from_inventory: carrying → :ok and the item is gone from inventory", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    {:ok, _} = Facade.give_to_actor(f, "apple")
    assert has_item?(store, inv, "apple")

    # Bare status only — exactly :ok, never echoing the item's uuid/internals.
    assert :ok === Facade.consume_from_inventory(f, "apple")
    refute has_item?(store, inv, "apple")
  end

  test "consume_from_inventory: not carrying → :not_carrying; blank/whitespace → :not_carrying (fail closed)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)
    {:ok, _} = Facade.give_to_actor(f, "apple")

    assert {:error, :not_carrying} = Facade.consume_from_inventory(f, "ghost")
    # Blank/whitespace must NOT match "anything held" — fail closed.
    assert {:error, :not_carrying} = Facade.consume_from_inventory(f, "")
    assert {:error, :not_carrying} = Facade.consume_from_inventory(f, "   ")
    # And the held item survived the blank calls.
    assert has_item?(store, inv, "apple")
  end

  test "consume_from_inventory: no inventory → :no_inventory (no crash)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    f = lc_facade(trusted_ctx, obj_uuid, [], %{}, store)
    assert {:error, :refused} = Facade.consume_from_inventory(f, "anything")
  end

  test "consume_from_inventory: charged against the N=8 op cap → :spawn_limit on the 9th", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    inv = lc_dir(store, trusted_ctx, "inv")
    # Seed 9 items WITHOUT charging (direct commit), so the only charges are
    # consume_from_inventory's own — isolating its op-cap accounting.
    :ok = seed_entries(store, trusted_ctx, inv, for(i <- 1..9, do: "item#{i}.obj"))

    f = lc_facade(trusted_ctx, obj_uuid, [], %{inventory_uuid: inv}, store)

    for i <- 1..8, do: assert(:ok === Facade.consume_from_inventory(f, "item#{i}"))
    assert {:error, :refused} = Facade.consume_from_inventory(f, "item9")
  end

  # give_from_inventory harness: builds root → "players" → <name> →
  # "inventory" for each recipient, a room, and the giver's inventory.
  defp give_world(store, ctx, opts) do
    root = lc_dir(store, ctx, "root")
    players = lc_dir(store, ctx, "players")
    room = lc_dir(store, ctx, "room")
    giver_inv = lc_dir(store, ctx, "giver_inv")

    # Link "players" into root (exact key, as the players registry uses).
    :ok = link_child(store, ctx, root, "players", players)

    invs =
      Map.new(Keyword.get(opts, :recipients, []), fn name ->
        pdir = lc_dir(store, ctx, "pdir_#{name}")
        rinv = lc_dir(store, ctx, "rinv_#{name}")
        :ok = link_child(store, ctx, pdir, "inventory", rinv)
        :ok = link_child(store, ctx, players, name, pdir)
        {name, rinv}
      end)

    # Place presence for the in-room recipients only.
    for name <- Keyword.get(opts, :in_room, []) do
      :ok = link_child(store, ctx, room, "#{name}.usr", UUID.uuid4())
    end

    %{root: root, players: players, room: room, giver_inv: giver_inv, invs: invs}
  end

  defp link_child(store, ctx, parent, name, child) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Commonplace.Tree.Schema.add_directory(schema, name, child)

    {meta, opts} =
      Commonplace.MUD.SignedWrite.opts_for(parent,
        store: store,
        signing_context: ctx,
        cert_cids: [],
        signer_id: nil,
        via_verb: nil
      )

    Commonplace.Store.CommitStoreClient.create_chained_commit(
      store,
      parent,
      Yelixer.Encoding.encode_update(schema),
      meta,
      opts
    )

    :ok
  end

  test "give_from_inventory: same-room recipient with inventory → :ok, item moves giver→recipient", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    w = give_world(store, trusted_ctx, recipients: ["bob"], in_room: ["bob"])

    f =
      lc_facade(
        trusted_ctx,
        obj_uuid,
        [],
        %{
          inventory_uuid: w.giver_inv,
          current_room_uuid: w.room,
          root_uuid: w.root,
          player_name: "alice"
        },
        store
      )

    {:ok, _} = Facade.give_to_actor(f, "coin")
    assert has_item?(store, w.giver_inv, "coin")

    # Bare status only.
    assert :ok === Facade.give_from_inventory(f, "coin", "bob")

    # Gone from the giver, present in the recipient's inventory under an
    # instance-unique key.
    refute has_item?(store, w.giver_inv, "coin")
    assert has_item?(store, w.invs["bob"], "coin")
  end

  test "give_from_inventory: ADDITIVE — a recipient's PRE-EXISTING same-named item is NOT clobbered", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    w = give_world(store, trusted_ctx, recipients: ["bob"], in_room: ["bob"])
    # Recipient already holds a "coin" (a plain "coin.obj" key).
    :ok = seed_entries(store, trusted_ctx, w.invs["bob"], ["coin.obj"])

    f =
      lc_facade(
        trusted_ctx,
        obj_uuid,
        [],
        %{inventory_uuid: w.giver_inv, current_room_uuid: w.room, root_uuid: w.root, player_name: "alice"},
        store
      )

    {:ok, _} = Facade.give_to_actor(f, "coin")
    assert :ok === Facade.give_from_inventory(f, "coin", "bob")

    # BOTH coins present — instance-unique deposit key never overwrote the
    # pre-existing item (additive-only, no-clobber).
    coin_entries = Enum.filter(lc_entry_names(store, w.invs["bob"]), &String.starts_with?(&1, "coin"))
    assert length(coin_entries) == 2
  end

  test "give_from_inventory: recipient NOT in room → :recipient_not_here (no-oracle: off-room name that EXISTS globally still :recipient_not_here)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    # carol is FULLY registered in the players tree (root→players→carol→
    # inventory) but is NOT present in the room. An off-room name must fail
    # identically to a nonexistent one — no global existence oracle.
    w = give_world(store, trusted_ctx, recipients: ["carol"], in_room: [])

    f =
      lc_facade(
        trusted_ctx,
        obj_uuid,
        [],
        %{inventory_uuid: w.giver_inv, current_room_uuid: w.room, root_uuid: w.root, player_name: "alice"},
        store
      )

    {:ok, _} = Facade.give_to_actor(f, "coin")

    # carol exists globally but is off-room → :recipient_not_here.
    assert {:error, :recipient_not_here} = Facade.give_from_inventory(f, "coin", "carol")
    # A totally nonexistent name → the SAME error (indistinguishable).
    assert {:error, :recipient_not_here} = Facade.give_from_inventory(f, "coin", "nobody")
    # The item never left the giver.
    assert has_item?(store, w.giver_inv, "coin")
    # carol's inventory was never touched.
    refute has_item?(store, w.invs["carol"], "coin")
  end

  test "give_from_inventory: blank recipient → :recipient_not_here; not carrying → :not_carrying; no inventory → :no_inventory", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    w = give_world(store, trusted_ctx, recipients: ["bob"], in_room: ["bob"])

    f =
      lc_facade(
        trusted_ctx,
        obj_uuid,
        [],
        %{inventory_uuid: w.giver_inv, current_room_uuid: w.room, root_uuid: w.root, player_name: "alice"},
        store
      )

    {:ok, _} = Facade.give_to_actor(f, "coin")

    # Blank recipient fails closed.
    assert {:error, :recipient_not_here} = Facade.give_from_inventory(f, "coin", "")
    assert {:error, :recipient_not_here} = Facade.give_from_inventory(f, "coin", "   ")
    # Not carrying the named item.
    assert {:error, :not_carrying} = Facade.give_from_inventory(f, "ghost", "bob")

    # No inventory at all → :no_inventory.
    f_no_inv =
      lc_facade(
        trusted_ctx,
        obj_uuid,
        [],
        %{current_room_uuid: w.room, root_uuid: w.root, player_name: "alice"},
        store
      )

    assert {:error, :refused} = Facade.give_from_inventory(f_no_inv, "coin", "bob")
  end

  describe "CX-a2gd: invoker identity accessors" do
    test "actor_name returns the SERVER-SET invoker display name; actor_ref returns the stable player-dir ref", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      f =
        lc_facade(
          trusted_ctx,
          obj_uuid,
          [obj_uuid],
          %{player_name: "alice", player_dir_uuid: "player-dir-abc"},
          store
        )

      assert Facade.actor_name(f) == "alice"
      assert Facade.actor_ref(f) == "player-dir-abc"
    end

    test "the accessors read ONLY the bound ctx — a different invoker's facade yields THAT invoker (invoker-only, no cross-read)", %{
      store: store,
      obj_uuid: obj_uuid,
      trusted_ctx: trusted_ctx
    } do
      # There is no parameter to name another player — each facade can only
      # ever surface its OWN bound invoker. Two facades, two identities.
      alice = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{player_name: "alice", player_dir_uuid: "pd-alice"}, store)
      bob = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{player_name: "bob", player_dir_uuid: "pd-bob"}, store)

      assert Facade.actor_name(alice) == "alice"
      assert Facade.actor_ref(alice) == "pd-alice"
      assert Facade.actor_name(bob) == "bob"
      assert Facade.actor_ref(bob) == "pd-bob"
    end

    test "missing identity fields → nil (no crash)", %{store: store, obj_uuid: obj_uuid, trusted_ctx: trusted_ctx} do
      f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)
      assert Facade.actor_name(f) == nil
      assert Facade.actor_ref(f) == nil
    end
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

    test "PIN 1 (CX-r8vp STRENGTHENED): the thin verb-facing facade drops the WHOLE ctx; inspect surfaces no key bytes",
         %{
           facade: facade,
           trusted_ctx: trusted_ctx
         } do
      thin = Facade.to_verb_facing(facade)

      # STRONGER than the old scrub (which left a scrubbed-but-present ctx):
      # the entire ctx is gone, so signing_context/private_key are wholly
      # unreachable via world.ctx.* / Map.get / destructure.
      assert thin.ctx == nil

      # inspect(world) AND world.ctx surface no private-key bytes.
      key_bytes = inspect(trusted_ctx.private_key)
      refute String.contains?(inspect(thin, limit: :infinity), key_bytes)
      refute String.contains?(inspect(thin.ctx, limit: :infinity), key_bytes)

      # Opaque Inspect render (belt) — no ctx, so no player name to show.
      assert inspect(thin) == "#MUD.World.Facade<player: ?>"
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

  # ---- CX-r8vp: thin-handle data surface (asserted, not incidental) ----
  # The verb-facing facade must carry ONLY inert display data. Every
  # capability/identity/store field is structurally ABSENT (nil/empty) — the
  # data-axis close that generalizes the P0 signer-material move.

  describe "CX-r8vp: thin-handle data surface" do
    setup %{store: store, trusted_ctx: trusted_ctx, obj_uuid: obj_uuid} do
      full =
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

      %{full: full}
    end

    test "every capability/identity/store field is nil/empty on the thin handle", %{full: full} do
      thin = Facade.to_verb_facing(full)

      assert thin.store == nil
      assert thin.ctx == nil
      assert thin.owner_grant == MapSet.new()
      assert thin.via_verb == nil
      assert thin.object_uuid == nil
    end

    test "Map.get and destructure paths reach nothing sensitive", %{full: full} do
      thin = Facade.to_verb_facing(full)

      # Map.get (a field-read bypass) yields nil.
      assert Map.get(thin, :ctx) == nil
      assert Map.get(thin, :store) == nil

      # destructure yields nil.
      assert match?(%{ctx: nil}, thin)
      %{ctx: c} = thin
      assert c == nil
    end

    test "host_kind (inert display data) is preserved on the thin handle", %{full: full} do
      thin = Facade.to_verb_facing(full)
      assert thin.host_kind == full.host_kind
    end
  end

  # CX-3x5a output-hygiene fix — `emit_author_diagnostic/2`'s player tell
  # (the dim "(verb note: ...)" line) is now scoped to "is the invoker the
  # verb's author": a non-author invoker (the common case for a
  # shared/curated verb) can't act on verb-debug jargon like "(verb note:
  # consume → requires_object_host)", so the tell must be suppressed FROM
  # THE PLAYER while staying loud on the ops side (unconditional
  # `Logger.warning` — the CX-3x5a guarantee is ops visibility, not player
  # visibility). These are direct-call unit tests of `emit_verb_drops/2`
  # (bypassing full player-session dispatch, mirroring the pin tests above).
  describe "CX-3x5a output-hygiene: author-scoped :verb_diagnostic player tell" do
    setup %{store: store, trusted_ctx: trusted_ctx, uncapped_ctx: uncapped_ctx} do
      case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      # These fixture docs only need a resolvable (or absent) SIGNER on
      # their latest commit — the local-write trust gate itself isn't
      # under test here, so relax it to :dry_run just for fixture setup
      # (an untrusted/unsigned signer would otherwise be REJECTED, not
      # merely distrusted) and restore :enforce (this file's standing
      # config) before the actual test body runs.
      Application.put_env(:commonplace, :local_write_gate, :dry_run)
      author_source_uuid = create_signed_source_doc(store, trusted_ctx)
      stranger_source_uuid = create_signed_source_doc(store, uncapped_ctx)
      unsigned_source_uuid = create_signed_source_doc(store, nil)
      Application.put_env(:commonplace, :local_write_gate, :enforce)

      %{
        author_source_uuid: author_source_uuid,
        stranger_source_uuid: stranger_source_uuid,
        unsigned_source_uuid: unsigned_source_uuid
      }
    end

    test "AUTHOR invoker (identity matches the verb source's signer) → the :verb_diagnostic tell IS delivered",
         %{store: store, trusted_ctx: trusted_ctx, author_source_uuid: author_source_uuid} do
      player_uuid = "player-#{:rand.uniform(999_999_999_999)}"
      Commonplace.MUD.Topics.subscribe_player_tell(player_uuid)

      full =
        Facade.new(
          %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil, player_uuid: player_uuid},
          nil,
          [],
          {author_source_uuid, "some-host"},
          store
        )

      log =
        capture_log(fn ->
          Facade.__accumulate__(:destroy_child, {:error, :not_found})
          assert :ok = Facade.emit_verb_drops(full, __MODULE__)
        end)

      assert_receive {"red:" <> ^player_uuid, %{kind: :verb_diagnostic, text: text}}
      assert text =~ "destroy_child"
      assert text =~ "not_found"

      assert log =~ "safe-verb author diagnostic"
      assert log =~ "destroy_child"
    end

    test "NON-AUTHOR invoker (a different identity than the verb source's signer) → no player tell, but the drop IS logged",
         %{store: store, uncapped_ctx: stranger_invoker_ctx, author_source_uuid: author_source_uuid} do
      player_uuid = "player-#{:rand.uniform(999_999_999_999)}"
      Commonplace.MUD.Topics.subscribe_player_tell(player_uuid)

      full =
        Facade.new(
          %{signing_context: stranger_invoker_ctx, cert_cids: [], signer_id: nil, player_uuid: player_uuid},
          nil,
          [],
          {author_source_uuid, "some-host"},
          store
        )

      log =
        capture_log(fn ->
          Facade.__accumulate__(:destroy_child, {:error, :not_found})
          assert :ok = Facade.emit_verb_drops(full, __MODULE__)
        end)

      refute_receive {"red:" <> ^player_uuid, %{kind: :verb_diagnostic}}, 100

      assert log =~ "safe-verb author diagnostic"
      assert log =~ "destroy_child"
      assert log =~ "not_found"
    end

    test "unresolvable verb author (unsigned source doc) → no player tell, but the drop IS logged (fail-closed)",
         %{store: store, trusted_ctx: trusted_ctx, unsigned_source_uuid: unsigned_source_uuid} do
      player_uuid = "player-#{:rand.uniform(999_999_999_999)}"
      Commonplace.MUD.Topics.subscribe_player_tell(player_uuid)

      full =
        Facade.new(
          %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil, player_uuid: player_uuid},
          nil,
          [],
          {unsigned_source_uuid, "some-host"},
          store
        )

      log =
        capture_log(fn ->
          Facade.__accumulate__(:destroy_child, {:error, :not_found})
          assert :ok = Facade.emit_verb_drops(full, __MODULE__)
        end)

      refute_receive {"red:" <> ^player_uuid, %{kind: :verb_diagnostic}}, 100
      assert log =~ "safe-verb author diagnostic"
    end

    test "curated-verb shape (via_verb source uuid does not resolve at all) → no player tell, still logged (fail-closed)",
         %{store: store, trusted_ctx: trusted_ctx} do
      player_uuid = "player-#{:rand.uniform(999_999_999_999)}"
      Commonplace.MUD.Topics.subscribe_player_tell(player_uuid)

      full =
        Facade.new(
          %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil, player_uuid: player_uuid},
          nil,
          [],
          {"never-created-uuid", "curated-host"},
          store
        )

      log =
        capture_log(fn ->
          Facade.__accumulate__(:destroy_child, {:error, :not_found})
          assert :ok = Facade.emit_verb_drops(full, __MODULE__)
        end)

      refute_receive {"red:" <> ^player_uuid, %{kind: :verb_diagnostic}}, 100
      assert log =~ "safe-verb author diagnostic"
    end

    test "permission-class drops ({:owner_grant_exceeded}) still route to the player-notice unchanged (regression guard)",
         %{store: store, trusted_ctx: trusted_ctx, author_source_uuid: author_source_uuid} do
      player_uuid = "player-#{:rand.uniform(999_999_999_999)}"
      Commonplace.MUD.Topics.subscribe_player_tell(player_uuid)

      # emit_permission_refusal is untouched by this fix — only the
      # AUTHOR-class branch (emit_author_diagnostic) got audience scoping.
      full =
        Facade.new(
          %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil, player_uuid: player_uuid},
          nil,
          [],
          {author_source_uuid, "some-host"},
          store
        )

      Facade.__accumulate__(:set_attr, {:error, :owner_grant_exceeded})
      assert :ok = Facade.emit_verb_drops(full, __MODULE__)

      assert_receive {"red:" <> ^player_uuid, %{kind: :notice, text: text}}
      assert text =~ "Nothing happens"
    end
  end

  defp create_signed_source_doc(store, nil) do
    uuid = UUID.uuid4()
    update = Encoding.encode_update(Yelixer.Doc.new())
    %Commonplace.Store.Commit{} = CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp create_signed_source_doc(store, %SigningContext{} = signing_context) do
    uuid = UUID.uuid4()
    update = Encoding.encode_update(Yelixer.Doc.new())

    {metadata, commit_opts} =
      Commonplace.MUD.SignedWrite.opts_for(uuid, signing_context: signing_context, store: store)

    %Commonplace.Store.Commit{} = CommitStore.create_commit(store, uuid, update, nil, metadata, commit_opts)
    uuid
  end

  # CX-3x5a — the drop accumulator. (A) unit behavior of the choke point;
  # (B) REFLECTIVE COVERAGE proving the `AccumDef` `def`-override actually
  # wrapped every public method (the completeness backstop — belt with the
  # macro's suspenders).
  describe "CX-3x5a: drop accumulator" do
    test "(A) __accumulate__ records only {:error,_}, passes everything else through; drain reverses + clears" do
      # start clean (the accumulator is process-local)
      Facade.drain_errors()

      # Non-error returns are a pure pass-through, unchanged.
      assert Facade.__accumulate__(:m2, :ok) == :ok
      assert Facade.__accumulate__(:m3, {:ok, 7}) == {:ok, 7}
      assert Facade.__accumulate__(:m4, nil) == nil
      assert Facade.__accumulate__(:m5, false) == false
      assert Facade.__accumulate__(:m6, "a string") == "a string"
      assert Facade.__accumulate__(:m7, 42) == 42

      # CX-3x5a RETURN sanitization: an UNMAPPED reason is closed-by-default
      # (→ :refused) on the RETURNED value...
      assert Facade.__accumulate__(:m1, {:error, :r1}) == {:error, :refused}
      # ...and a nested/compound internal reason NEVER reaches the caller —
      # also :refused, never the raw tuple.
      assert Facade.__accumulate__(:m8, {:error, {:trust_rejected, :x}}) == {:error, :refused}

      # drain still yields the RAW reasons, unchanged — the accumulator/ops
      # path (drain_errors/permission_class?/author diagnostics) must keep
      # seeing the truth even though the caller only ever saw :refused.
      assert Facade.drain_errors() == [m1: :r1, m8: {:trust_rejected, :x}]
      assert Facade.drain_errors() == []
    end

    test "(A2) CX-3x5a RETURN sanitization end-to-end through a REAL public method — verb sees :refused, accumulator/ops still sees RAW, permission_class? routing intact",
         %{store: store, obj_uuid: obj_uuid, uncapped_ctx: uncapped_ctx} do
      Facade.drain_errors()

      facade =
        Facade.new(
          %{signing_context: uncapped_ctx, cert_cids: [], signer_id: nil},
          obj_uuid,
          [obj_uuid],
          {"verbs/poke.safe.elx", "owner-x"},
          store
        )

      # The VERB BODY (here: this test, calling the facade method the same
      # way a verb body would) sees ONLY the sanitized atom — never the raw
      # {:trust_rejected, _} tuple.
      assert {:error, :refused} = Facade.set_attr(facade, "note", "poked")

      # The SAME failure is still RAW in the accumulator — drain_errors
      # (the ops/author path) is completely unaffected by the RETURN-side
      # sanitization; `permission_class?/1`'s routing on this exact raw
      # shape ({:trust_rejected, _}) is covered by the "permission-class
      # drops ... still route to the player-notice unchanged" test below,
      # which drives the SAME raw reason through `emit_verb_drops/2`.
      assert [{:set_attr, {:trust_rejected, _}}] = Facade.drain_errors()
    end

    test "CX-3x5a: an UNMAPPED/unknown internal reason is closed-by-default → the verb body sees :refused, never the raw reason" do
      Facade.drain_errors()

      assert Facade.__accumulate__(:some_method, {:error, :some_brand_new_internal_reason}) ==
               {:error, :refused}

      assert Facade.drain_errors() == [some_method: :some_brand_new_internal_reason]
    end

    test "CX-3x5a: a clean domain reason (:not_found) passes through UNCHANGED to the verb body" do
      Facade.drain_errors()
      assert Facade.__accumulate__(:describe, {:error, :not_found}) == {:error, :not_found}
      assert Facade.drain_errors() == [describe: :not_found]
    end

    test "(B) REFLECTIVE COVERAGE: a representative set of facade methods each accumulate their {:error} (the macro wrapped them)",
         %{store: store, obj_uuid: obj_uuid, trusted_ctx: trusted_ctx} do
      # Fresh per-run counters so lifecycle charges never interfere.
      Process.delete(:cp_safe_verb_lifecycle_ops)
      Facade.drain_errors()

      # EMPTY owner_grant → grant-gated writes fail :owner_grant_exceeded
      # (checked BEFORE any store write); ctx carries arbitrary uuids and a
      # nil inventory so the non-grant methods hit their own error triggers.
      ctx = %{
        signing_context: trusted_ctx,
        cert_cids: [],
        signer_id: nil,
        current_room_uuid: "room-does-not-exist",
        inventory_uuid: nil
      }

      fobj = %{Facade.new(ctx, obj_uuid, [], {"v.safe.elx", "o"}, store) | host_kind: :object}

      # {method_atom, invocation} — one per public method, inducing an error:
      #  * grant-gated writes → :owner_grant_exceeded (empty grant)
      #  * lifecycle/inventory → their own per-method trigger (nil inventory,
      #    bad arg, not-minted, blank name)
      #  * reads → :not_found (bogus uuid)
      invocations = [
        set_attr: fn -> Facade.set_attr(fobj, "k", "v") end,
        put_state: fn -> Facade.put_state(fobj, "k", "v") end,
        move_object: fn -> Facade.move_object(fobj, "dest-uuid") end,
        create_child: fn -> Facade.create_child(fobj, "child") end,
        destroy_child: fn -> Facade.destroy_child(fobj, "child") end,
        spawn: fn -> Facade.spawn(fobj, "rock") end,
        transfer: fn -> Facade.transfer(fobj, "item-uuid", "dest-uuid") end,
        random: fn -> Facade.random(fobj, -1) end,
        give_to_actor: fn -> Facade.give_to_actor(fobj, "reward") end,
        consume_from_inventory: fn -> Facade.consume_from_inventory(fobj, "   ") end,
        give_from_inventory: fn -> Facade.give_from_inventory(fobj, "a", "b") end,
        configure_attr: fn -> Facade.configure_attr(fobj, "not-minted-uuid", "k", "v") end,
        configure_state: fn -> Facade.configure_state(fobj, "not-minted-uuid", "k", "v") end,
        describe: fn -> Facade.describe(fobj, "bogus-uuid") end,
        get_attr: fn -> Facade.get_attr(fobj, "bogus-uuid") end,
        look: fn -> Facade.look(fobj) end
      ]

      for {method, fun} <- invocations do
        Facade.drain_errors()
        result = fun.()

        assert match?({:error, _}, result),
               "#{method} must return an {:error, _} to induce a drop, got: #{inspect(result)}"

        drained = Facade.drain_errors()

        assert Keyword.has_key?(drained, method),
               "#{method} did NOT accumulate — the def-override failed to wrap it (drained=#{inspect(drained)})"
      end
    end
  end
end
