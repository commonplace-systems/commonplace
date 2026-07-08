defmodule Commonplace.MUD.VerbsSafeDispatchTest do
  @moduledoc """
  CX-cj3t.5 build spec §2 — the live untrusted-`@verb` dispatch gate.
  Pins 1-8 (incl. 6b) against `Commonplace.MUD.Verbs.dispatch/2` itself
  (not just the CX-ndvi mechanism it wires in — that mechanism already
  has its own unit coverage in `SafeVerbTest`/`World.FacadeTest`/
  `DefineVerbGateTest`).

  Setup mirrors `Commonplace.MUD.SectionOwnershipTest` (named
  `Commonplace.Store.Supervisor` trio + capability minting) plus
  `Commonplace.MUD.VerbsDigLinkTest`'s `Commonplace.Green.Bursar`
  bring-up (needed because `take`/`Facade.move` cross-directory moves
  go through the green-token move path).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{Parser, Schemas, SignedWrite, VerbSource, Verbs, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.MUD.SafeVerb.Bounds
  alias Commonplace.MUD.Sections
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_safe_dispatch_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"safe_dispatch_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"safe_dispatch_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"safe_dispatch_tss_#{n}",
       pending_imports_name: :"safe_dispatch_pi_#{n}"}
    )

    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    root_uuid = UUID.uuid4()

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(root_uuid: root_uuid, store: store, sweep_interval: 60_000)

    old_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid)
      File.rm_rf!(dir)
    end)

    Commonplace.Code.SourceDoc.reset_cache()

    {:ok, room_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "The Yard", description: "a plain yard"}),
        store
      )

    {:ok, inventory_uuid} = Schemas.create_dir_with_meta(nil, nil, store)

    %{store: store, root_uuid: root_uuid, room_uuid: room_uuid, inventory_uuid: inventory_uuid}
  end

  # ---- test helpers ----

  defp base_ctx(store, room_uuid, inventory_uuid, opts \\ []) do
    %{
      player_name: Keyword.get(opts, :player_name, "alice"),
      player_uuid: Keyword.get(opts, :player_uuid, UUID.uuid4()),
      player_dir_uuid: Keyword.get(opts, :player_dir_uuid, UUID.uuid4()),
      inventory_uuid: inventory_uuid,
      current_room_uuid: room_uuid,
      presence_filename: "alice.usr",
      root_uuid: Keyword.get(opts, :root_uuid, UUID.uuid4()),
      store: store,
      signing_context: Keyword.get(opts, :signing_context),
      signer_id: Keyword.get(opts, :signer_id),
      cert_cids: Keyword.get(opts, :cert_cids, [])
    }
  end

  defp add_dir_entry(store, parent_uuid, name, child_uuid, opts \\ []) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  defp create_object(store, name, opts \\ []) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        opts
      )

    uuid
  end

  defp raw_meta(store, dir_uuid, filename) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, filename)
    {:ok, doc} = DocBuilder.reconstruct_doc(store, entry.node_id)
    Jason.decode!(ContentType.get_content(doc))
  end

  # ---- pin 1: builtins win (CX-66ca) ----

  test "pin 1: a `take` safe verb on a room object never fires — the builtin pickup runs instead", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    bell_uuid = create_object(store, "bell")
    :ok = add_dir_entry(store, room_uuid, "bell.obj", bell_uuid)

    body = ~s|Commonplace.MUD.World.Facade.set_attr(world, "verb_fired", true)|
    assert :ok = VerbSource.save_safe_verb(bell_uuid, "take", body, [bell_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    cmd = Parser.parse("take bell")

    assert {:reply, text} = Verbs.dispatch(cmd, ctx)
    assert text =~ "take"

    # Builtin pickup ran: the bell is in inventory, gone from the room.
    assert Enum.any?(World.list_objects_in(inventory_uuid, store), &(&1.node_id == bell_uuid))
    refute Enum.any?(World.list_objects_in(room_uuid, store), &(&1.node_id == bell_uuid))

    # The safe verb never ran: no `verb_fired` key landed on the bell's
    # own meta doc.
    meta = raw_meta(store, bell_uuid, Schemas.object_filename())
    refute Map.has_key?(meta, "verb_fired")
  end

  # ---- pin 2: target resolution by direct-object noun (CX-mczs) ----

  test "pin 2: `poke stick` fires stick's verb, `poke rock` fires rock's — never the other object's", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    rock_uuid = create_object(store, "rock")
    stick_uuid = create_object(store, "stick")
    :ok = add_dir_entry(store, room_uuid, "rock.obj", rock_uuid)
    :ok = add_dir_entry(store, room_uuid, "stick.obj", stick_uuid)

    body = ~s|Commonplace.MUD.World.Facade.set_attr(world, "poked", Map.get(args, :target))|

    assert :ok = VerbSource.save_safe_verb(rock_uuid, "poke", body, [rock_uuid], store)
    assert :ok = VerbSource.save_safe_verb(stick_uuid, "poke", body, [stick_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert :ok = Verbs.dispatch(Parser.parse("poke stick"), ctx)
    stick_meta = raw_meta(store, stick_uuid, Schemas.object_filename())
    rock_meta = raw_meta(store, rock_uuid, Schemas.object_filename())
    assert stick_meta["poked"] == "stick"
    refute Map.has_key?(rock_meta, "poked")

    assert :ok = Verbs.dispatch(Parser.parse("poke rock"), ctx)
    rock_meta2 = raw_meta(store, rock_uuid, Schemas.object_filename())
    assert rock_meta2["poked"] == "rock"
  end

  # ---- pin 3: safe path wired + legacy verb refused (CX-qom0) ----

  test "pin 3: a safe verb runs through the Facade (invoker-signed, via_verb tagged); a legacy verb on a different object is refused", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    {pub, priv} = Signing.generate_keypair()
    identity = "inv-#{:rand.uniform(999_999_999_999)}"
    inv_ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    widget_uuid = create_object(store, "widget")
    :ok = add_dir_entry(store, room_uuid, "widget.obj", widget_uuid)

    safe_body = ~s|Commonplace.MUD.World.Facade.set_attr(world, "poked", "yes")|
    assert :ok = VerbSource.save_safe_verb(widget_uuid, "poke", safe_body, [widget_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid, signing_context: inv_ctx)
    assert :ok = Verbs.dispatch(Parser.parse("poke widget"), ctx)

    {:ok, schema} = Schemas.load_dir_schema(widget_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.object_filename())
    assert {:ok, head} = CommitStore.latest_commit(store, entry.node_id)
    assert head.signer_id == Signing.signer_id(identity, pub)
    assert {:ok, source_uuid} = VerbSource.find_safe_source(widget_uuid, "poke", store)
    assert {source_uuid, "widget.obj"} == head.metadata[:via_verb]

    meta = raw_meta(store, widget_uuid, Schemas.object_filename())
    assert meta["poked"] == "yes"

    # CX-qom0: a legacy (full-defmodule, ambient-reach) verb on a
    # DIFFERENT object is no longer dispatchable through
    # `Verbs.dispatch/2` at all — `run_legacy_user_verb/5` passes
    # `require_safe_wrapper: true` to `VerbSource.run_verb/5` for every
    # dispatch (not just ones a real `PlayerSession` originates;
    # `Verbs.dispatch/2` is the single untrusted-command surface, with no
    # caller-trust distinction), so `SourceDoc.compile` rejects the
    # author's raw `defmodule` as `:not_substrate_wrapped`. This
    # supersedes the old CX-ndvi §4 "legacy coexistence, no regression"
    # expectation this pin used to assert — the migration boundary is
    # now "legacy verbs must be re-authored as safe verbs", not
    # "legacy verbs keep running forever alongside safe ones".
    gizmo_uuid = create_object(store, "gizmo")
    :ok = add_dir_entry(store, room_uuid, "gizmo.obj", gizmo_uuid)

    legacy_src = """
    defmodule Commonplace.UserCode.Mud.Verb.LegacyRing do
      def run(ctx) do
        Commonplace.MUD.World.broadcast_room(ctx.current_room_uuid, %{kind: :custom, text: "ding"})
        :ok
      end
    end
    """

    assert :ok = VerbSource.save_verb(gizmo_uuid, "ring", legacy_src, store)

    assert {:error, msg} = Verbs.dispatch(Parser.parse("ring gizmo"), ctx)
    assert msg =~ "unavailable"
  end

  # ---- pin 4: section_scope from tree position (foreign-section pin) ----

  test "pin 4: a safe verb whose body content names a foreign section still gates on [host_uuid] — content can't widen scope",
       %{store: store, room_uuid: room_uuid, inventory_uuid: inventory_uuid} do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    {pub, priv} = Signing.generate_keypair()
    identity = "def-#{:rand.uniform(999_999_999_999)}"
    definer_ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    trinket_uuid = create_object(store, "trinket")
    :ok = add_dir_entry(store, room_uuid, "trinket.obj", trinket_uuid)

    foreign_uuid = UUID.uuid4()

    # The body's own CONTENT names a foreign uuid — but there is no
    # mechanism reading it as a scope; the define-walk is anchored on
    # `[trinket_uuid]` (the real host), so an unauthorized definer is
    # STILL denied even though the body "claims" a different section.
    body = ~s|"#{foreign_uuid}"; Commonplace.MUD.World.Facade.set_attr(world, "poked", "yes")|

    assert {:error, {:execution_denied, _}} =
             VerbSource.save_safe_verb(trinket_uuid, "poke", body, [trinket_uuid], store,
               signing_context: definer_ctx
             )

    # Unlike a lint violation, a define-gate denial happens at COMPILE
    # time (after the source doc is already persisted, so the author can
    # keep editing) — the source is there, but every dispatch re-checks
    # the gate at verify time.
    assert {:ok, _source_uuid} = VerbSource.find_safe_source(trinket_uuid, "poke", store)

    # Dispatch re-compiles under the SAME `[trinket_uuid]` gate (never
    # `[foreign_uuid]` — the body's content has no channel to reach
    # `section_scope` at all) and is denied again: a clean player-facing
    # error, never a crash, never a fallback to some other verb/builtin.
    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert {:error, _msg} = Verbs.dispatch(Parser.parse("poke trinket"), ctx)
  end

  # ---- pin 5: intersection denial (owner_grant ceiling, default no-cert case) ----

  test "pin 5: a safe verb attempting a facade write outside owner_grant is denied — nothing lands, no crash", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    box_uuid = create_object(store, "box")
    :ok = add_dir_entry(store, room_uuid, "box.obj", box_uuid)

    elsewhere_uuid = UUID.uuid4()

    # No section cert exists anywhere for box_uuid, so
    # `owner_grant_for/2` defaults to `MapSet.new([box_uuid])` — the verb
    # tries to `move` its own bound object, which touches
    # `{object_uuid, current_room_uuid, dest_dir_uuid}`. `current_room_uuid`
    # (the room) is NOT in the default grant, so the facade denies BEFORE
    # attempting any commit.
    body = ~s|Commonplace.MUD.World.Facade.move_object(world, "#{elsewhere_uuid}")|
    assert :ok = VerbSource.save_safe_verb(box_uuid, "shove", body, [box_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    # Direct call proves the exact denial shape (mirrors
    # `World.FacadeTest` pin 3, but exercised via the SAME owner_grant
    # default the dispatcher computes when no cert covers the host).
    facade = Commonplace.MUD.World.Facade.new(ctx, box_uuid, [box_uuid], {"verbs/shove.safe.elx", "box.obj"}, store)

    assert {:ok, {:error, :refused}} =
             VerbSource.run_safe_verb(box_uuid, "shove", [box_uuid], facade, %{}, store)

    # Through full dispatch: no crash, and the box never left the room.
    assert :ok = Verbs.dispatch(Parser.parse("shove box"), ctx)
    assert Enum.any?(World.list_objects_in(room_uuid, store), &(&1.node_id == box_uuid))
  end

  # ---- pin 6: define-gate denial at dispatch (unauthorized/revoked definer) ----

  test "pin 6: an unauthorized definer's safe verb never dispatches — clean error, no crash", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    {pub, priv} = Signing.generate_keypair()
    identity = "stranger-#{:rand.uniform(999_999_999_999)}"
    stranger_ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    lamp_uuid = create_object(store, "lamp")
    :ok = add_dir_entry(store, room_uuid, "lamp.obj", lamp_uuid)

    body = ~s|Commonplace.MUD.World.Facade.set_attr(world, "on", true)|

    assert {:error, {:execution_denied, _}} =
             VerbSource.save_safe_verb(lamp_uuid, "light", body, [lamp_uuid], store,
               signing_context: stranger_ctx
             )

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert {:error, _msg} = Verbs.dispatch(Parser.parse("light lamp"), ctx)
  end

  # ---- pin 6b (RIDER 1): verified-chains-only owner ceiling ----

  test "pin 6b: revoking the owner's section cert collapses owner_grant back to the host-only default", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    {root_pub, root_priv} = Signing.generate_keypair()
    root_identity = "root-#{:rand.uniform(999_999_999_999)}"
    root_ctx = %SigningContext{identity_uuid: root_identity, private_key: root_priv, public_key: root_pub}

    {owner_pub, owner_priv} = Signing.generate_keypair()
    owner_identity = "owner-#{:rand.uniform(999_999_999_999)}"
    owner_ctx = %SigningContext{identity_uuid: owner_identity, private_key: owner_priv, public_key: owner_pub}

    # Both pinned: root anchors the section cert's chain (VerifyChain's
    # `check_root`); owner being pinned too keeps this pin isolated to
    # the OWNER-GRANT (gate b) ceiling — invoker authority (gate a) and
    # the define-gate both trivially pass via the pinned-root fast path,
    # so only RIDER 1's verified-chains-only union is under test.
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{
        root_identity => Signing.encode_key(root_pub),
        owner_identity => Signing.encode_key(owner_pub)
      }
    })

    chest_uuid = create_object(store, "chest")
    :ok = add_dir_entry(store, room_uuid, "chest.obj", chest_uuid)

    # A real directory doc (not just a bare uuid) — `Move.move` needs an
    # actual schema doc at the destination to add the moved entry to.
    dest_uuid = create_object(store, "elsewhere")

    assert {:ok, cap} =
             Sections.issue_section(root_ctx, {owner_identity, owner_pub}, [chest_uuid, room_uuid, dest_uuid],
               store: store,
               verbs: [:write]
             )

    # Saving the verb AS owner, with cert_cids naming the section cap,
    # lands a commit on `chest_uuid`'s own log carrying
    # `metadata.capability_proof = cap.id` (the cap's scope includes
    # `chest_uuid`, so `SignedWrite`'s cert-selection picks it) — this is
    # exactly the discovery signal `owner_grant_for/2` walks for, mirrored
    # from `Sections.auto_extend_for_new_room/3`.
    body = ~s|Commonplace.MUD.World.Facade.move_object(world, "#{dest_uuid}")|

    assert :ok =
             VerbSource.save_safe_verb(chest_uuid, "shove", body, [chest_uuid], store,
               signing_context: owner_ctx,
               cert_cids: [cap.id]
             )

    ctx = base_ctx(store, room_uuid, inventory_uuid, signing_context: owner_ctx)

    # BEFORE revocation: owner_grant = {chest, room, dest} (verified,
    # unrevoked chain) → the move (touches chest/room/dest) is permitted.
    assert :ok = Verbs.dispatch(Parser.parse("shove chest"), ctx)
    assert Enum.any?(World.list_objects_in(dest_uuid, store), &(&1.node_id == chest_uuid))
    refute Enum.any?(World.list_objects_in(room_uuid, store), &(&1.node_id == chest_uuid))

    # Revoke the section cert (root — the cert's own issuer, §2
    # path-issuer authority).
    assert {:ok, revocation} = Capability.revoke(root_ctx, cap.id)
    assert :ok = CommitStoreClient.store_revocation(store, revocation)

    # AFTER revocation: the revoked cert no longer contributes scope to
    # the union — owner_grant collapses to `MapSet.new([chest_uuid])`.
    # The chest is now sitting in `dest_uuid`; a next attempted move
    # (dest_uuid -> dest_uuid, scope-check only cares about set
    # membership, not physical sense) is denied at the (b) ceiling
    # because `dest_uuid` (the "current room" for this check) is no
    # longer in the collapsed grant.
    ctx2 = %{ctx | current_room_uuid: dest_uuid}

    facade =
      Commonplace.MUD.World.Facade.new(
        ctx2,
        chest_uuid,
        MapSet.new([chest_uuid]),
        {"verbs/shove.safe.elx", "chest.obj"},
        store
      )

    assert {:ok, {:error, :refused}} =
             VerbSource.run_safe_verb(chest_uuid, "shove", [chest_uuid], facade, %{}, store)

    assert :ok = Verbs.dispatch(Parser.parse("shove chest"), ctx2)
    assert Enum.any?(World.list_objects_in(dest_uuid, store), &(&1.node_id == chest_uuid))
  end

  # ---- pin 7: bounds mailbox-flush hygiene ----

  test "pin 7: a timed-out verb leaves no stray :DOWN/:result message in the caller's mailbox" do
    Application.put_env(:commonplace, :safe_verb_timeout_ms, 50)
    on_exit(fn -> Application.delete_env(:commonplace, :safe_verb_timeout_ms) end)

    loop = fn f -> f.(f) end

    assert {:error, :timeout} = Bounds.run(fn -> loop.(loop) end)

    # Give any (buggy, unflushed) late message a moment to actually land
    # before we assert the mailbox is clean.
    Process.sleep(100)
    assert Process.info(self(), :messages) == {:messages, []}

    # A second, unrelated receive in the SAME process would otherwise
    # inherit any stray tuple from the first call — prove it doesn't.
    assert {:error, :timeout} = Bounds.run(fn -> loop.(loop) end)
    Process.sleep(100)
    assert Process.info(self(), :messages) == {:messages, []}
  end

  # ---- FLAG-A pin: safe-vs-legacy SELECTION (plan pre-merge FIX 1) ----

  test "FLAG A: legacy fallback fires ONLY on a clean :not_found — a store/read error surfaces, never downgrades to legacy", %{
    store: store,
    room_uuid: room_uuid
  } do
    gem_uuid = create_object(store, "gem")
    :ok = add_dir_entry(store, room_uuid, "gem.obj", gem_uuid)

    # (a) real, loadable host with no `poke.safe.elx` → :legacy — the
    #     intended CX-ndvi §4 migration fallback.
    assert :legacy = Verbs.classify_verb_source(gem_uuid, "poke", store)

    # (b) a safe source present → {:safe, source_uuid}.
    body = ~s|Commonplace.MUD.World.Facade.set_attr(world, "poked", "yes")|
    assert :ok = VerbSource.save_safe_verb(gem_uuid, "poke", body, [gem_uuid], store)
    assert {:ok, source_uuid} = VerbSource.find_safe_source(gem_uuid, "poke", store)
    assert {:safe, ^source_uuid} = Verbs.classify_verb_source(gem_uuid, "poke", store)

    # (c) a store/read ERROR (host doc unreadable — `{:error, :missing}`
    #     from the schema load, NOT a clean `:not_found` miss) surfaces
    #     as an error: a transient read failure must never silently swap
    #     a facade-bounded safe verb for its ambient-ctx legacy twin.
    assert {:error, :missing} = Verbs.classify_verb_source(UUID.uuid4(), "poke", store)
  end

  # ---- pin 8: no regression — sanity smoke over builtins/builders ----

  test "pin 8: ordinary builtin/builder dispatch is unaffected", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert {:reply, look_text} = Verbs.dispatch(Parser.parse("look"), ctx)
    assert look_text =~ "The Yard"

    assert :ok = Verbs.dispatch(Parser.parse("say hello"), ctx)
    assert {:error, "Take what?"} = Verbs.dispatch(Parser.parse("take"), ctx)
  end
end
