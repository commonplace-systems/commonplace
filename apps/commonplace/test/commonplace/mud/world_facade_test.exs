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

  test "spawn: DEFAULT-safe — a plain object cannot spawn into the room (room not in owner_grant)", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    room = lc_dir(store, trusted_ctx, "room")
    # owner_grant is the default {object}, which does NOT cover the room.
    f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{current_room_uuid: room}, store)

    assert {:error, :owner_grant_exceeded} = Facade.spawn(f, "rock")
    refute "rock.obj" in lc_entry_names(store, room)
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
    assert "rock.obj" in lc_entry_names(store, room)
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
    refute "rock.obj" in lc_entry_names(store, room)
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
    assert "coin.obj" in lc_entry_names(store, inv)
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

  test "destroy_child: happy path — create then unlink a named child of the bound object", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    f = lc_facade(trusted_ctx, obj_uuid, [obj_uuid], %{}, store)

    assert {:ok, _} = Facade.create_child(f, "gear")
    assert "gear.obj" in lc_entry_names(store, obj_uuid)

    assert :ok = Facade.destroy_child(f, "gear")
    refute "gear.obj" in lc_entry_names(store, obj_uuid)
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
    assert "potion.obj" in lc_entry_names(store, inv)

    # Bind the verb to the carried item; EMPTY grant. locate_parent finds
    # it in the invoker's inventory → invoker-own exception → unlink.
    consumer = lc_facade(trusted_ctx, item_uuid, [], %{inventory_uuid: inv}, store)
    assert :ok = Facade.consume(consumer)
    refute "potion.obj" in lc_entry_names(store, inv)
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
end
