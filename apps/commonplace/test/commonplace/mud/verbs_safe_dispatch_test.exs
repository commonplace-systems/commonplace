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

    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "verb_fired", true)|
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
    refute get_in(meta, ["state", "verb_fired"])
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

    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "poked", Map.get(args, :target))|

    assert :ok = VerbSource.save_safe_verb(rock_uuid, "poke", body, [rock_uuid], store)
    assert :ok = VerbSource.save_safe_verb(stick_uuid, "poke", body, [stick_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert :ok = Verbs.dispatch(Parser.parse("poke stick"), ctx)
    stick_meta = raw_meta(store, stick_uuid, Schemas.object_filename())
    rock_meta = raw_meta(store, rock_uuid, Schemas.object_filename())
    assert get_in(stick_meta, ["state", "poked"]) == "stick"
    refute get_in(rock_meta, ["state", "poked"])

    assert :ok = Verbs.dispatch(Parser.parse("poke rock"), ctx)
    rock_meta2 = raw_meta(store, rock_uuid, Schemas.object_filename())
    assert get_in(rock_meta2, ["state", "poked"]) == "rock"
  end

  # ---- pin CX-bi84: room-first, verb-aware target resolution ----

  test "pin CX-bi84: object-verb noun resolution prefers the ROOM object that owns the verb over a carried name-match that lacks it",
       %{
         store: store,
         room_uuid: room_uuid,
         inventory_uuid: inventory_uuid
       } do
    vault_uuid = create_object(store, "Warded Vault")
    :ok = add_dir_entry(store, room_uuid, "warded vault.obj", vault_uuid)

    unlock_body = ~s|Commonplace.MUD.World.Facade.put_state(world, "unlocked", true)|
    assert :ok = VerbSource.save_safe_verb(vault_uuid, "unlock", unlock_body, [vault_uuid], store)

    {:ok, key_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "brass key", aliases: ["vault key"]}),
        store
      )

    :ok = add_dir_entry(store, inventory_uuid, "brass key.obj", key_uuid)

    # Sanity check: the carried key really does answer to "vault" (via its
    # alias) — this is the precondition that made pre-fix resolution pick it.
    assert {:ok, entry} = World.find_entry_by_name(inventory_uuid, "vault", store)
    assert entry.node_id == key_uuid

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert :ok = Verbs.dispatch(Parser.parse("unlock vault"), ctx)

    vault_meta = raw_meta(store, vault_uuid, Schemas.object_filename())
    assert get_in(vault_meta, ["state", "unlocked"]) == true

    key_meta = raw_meta(store, key_uuid, Schemas.object_filename())
    refute get_in(key_meta, ["state", "unlocked"])
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

    safe_body = ~s|Commonplace.MUD.World.Facade.put_state(world, "poked", "yes")|
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
    assert get_in(meta, ["state", "poked"]) == "yes"

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
    body = ~s|"#{foreign_uuid}"; Commonplace.MUD.World.Facade.put_state(world, "poked", "yes")|

    # The body's CONTENT names a foreign uuid, but there is no mechanism that
    # reads it as a scope: authoring authority is anchored on the real host
    # (`trinket_uuid`), never on anything the body claims. The unauthorized
    # definer is refused (body lints clean, so `{:error, _}` is an authority
    # refusal). CX-fogy L3 refuses at AUTHORING (the zoned verbs/ dir's :write
    # carve, anchored on trinket's zone) rather than the pre-L3 compile define-
    # gate — either way the body's foreign-section content can NEVER widen scope.
    assert {:error, _} =
             VerbSource.save_safe_verb(trinket_uuid, "poke", body, [trinket_uuid], store,
               signing_context: definer_ctx
             )

    # Nothing persisted — the author lacked host authority, so the write never
    # landed (strictly stronger than the pre-L3 persist-then-deny-at-dispatch).
    assert :not_found = VerbSource.find_safe_source(trinket_uuid, "poke", store)

    # And dispatch finds no such verb: `:unhandled` (nothing persisted), never a
    # crash, never a fallback to some other verb/builtin — and NEVER a scope
    # widened by the body's foreign-uuid content.
    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert :unhandled = Verbs.dispatch(Parser.parse("poke trinket"), ctx)
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

    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "on", true)|

    # The stranger holds no authority over the lamp's zone. CX-fogy L3 refuses
    # this at AUTHORING (the zoned verbs/ dir's :write carve) rather than the
    # pre-L3 compile-time define-gate — strictly stronger, and the "never
    # dispatches" guarantee below is unchanged (body lints clean, so `{:error, _}`
    # is an authority refusal, not a lint fault). Nothing lands.
    assert {:error, _} =
             VerbSource.save_safe_verb(lamp_uuid, "light", body, [lamp_uuid], store,
               signing_context: stranger_ctx
             )

    assert :not_found = VerbSource.find_safe_source(lamp_uuid, "light", store)

    # Nothing persisted → dispatch finds no such verb: `:unhandled`, no crash.
    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert :unhandled = Verbs.dispatch(Parser.parse("light lamp"), ctx)
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
    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "poked", "yes")|
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

  # ---- M2 (CX-z6ub §3): OVERRIDABLE standard verbs (own-verb → node baseline) ----

  test "pin M2.1a (CX-z6ub): a `look` override on the room FIRES — an OVERRIDABLE standard verb resolves the host's own verb first", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "looked", "custom")|
    assert :ok = VerbSource.save_safe_verb(room_uuid, "look", body, [room_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    Verbs.dispatch(Parser.parse("look"), ctx)

    # The room's OWN `look` ran (its state effect landed) — pre-M2, builtins-first
    # meant this override was structurally unreachable; M2 makes `look` overridable.
    room_meta = raw_meta(store, room_uuid, Schemas.room_filename())
    assert get_in(room_meta, ["state", "looked"]) == "custom"
  end

  test "pin M2.1b (CX-z6ub): a bare `look` is the ROOM's — an OBJECT's `look` verb never hijacks a bare look", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    gizmo_uuid = create_object(store, "gizmo")
    :ok = add_dir_entry(store, room_uuid, "gizmo.obj", gizmo_uuid)
    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "peeked", "yes")|
    assert :ok = VerbSource.save_safe_verb(gizmo_uuid, "look", body, [gizmo_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    Verbs.dispatch(Parser.parse("look"), ctx)

    # Bare `look` resolves on the ROOM host only (never an object scope-scan), so
    # the gizmo's `look` verb did NOT fire — its state effect never landed.
    gizmo_meta = raw_meta(store, gizmo_uuid, Schemas.object_filename())
    refute get_in(gizmo_meta, ["state", "peeked"])
  end

  test "pin M2.1c (CX-z6ub): a `go` override never fires — `go` is LOCKED (visitor anti-trap), the builtin runs", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    # `go` is NOT in @overridable → builtins-first → a citizen's same-named safe
    # verb is structurally unreachable (a room owner can't trap a visitor by
    # overriding movement). Same guarantee pin 1 proves for `take` (anti-theft).
    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "trapped", "yes")|
    assert :ok = VerbSource.save_safe_verb(room_uuid, "go", body, [room_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    Verbs.dispatch(Parser.parse("go north"), ctx)

    room_meta = raw_meta(store, room_uuid, Schemas.room_filename())
    refute get_in(room_meta, ["state", "trapped"])
  end

  # ---- M2.2 (CX-z6ub §3): six OVERRIDABLE standard verb baselines ----

  test "pin M2.2a (CX-z6ub): the `examine` node BASELINE runs on a fresh object — name + description, no override", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    idol_uuid = create_object(store, "idol")
    :ok = add_dir_entry(store, room_uuid, "idol.obj", idol_uuid)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    # No override authored → the node-signed baseline runs: name + description.
    assert {:reply, text} = Verbs.dispatch(Parser.parse("examine idol"), ctx)
    assert text =~ "idol"
  end

  test "pin M2.2b (CX-z6ub): a citizen's `examine` override on the host FIRES instead of the node baseline", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    idol_uuid = create_object(store, "idol")
    :ok = add_dir_entry(store, room_uuid, "idol.obj", idol_uuid)

    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "examined", "custom")|
    assert :ok = VerbSource.save_safe_verb(idol_uuid, "examine", body, [idol_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    Verbs.dispatch(Parser.parse("examine idol"), ctx)

    # The idol's OWN `examine` ran (its state effect landed) — `examine` is
    # overridable, so the host's own verb wins over the node baseline.
    meta = raw_meta(store, idol_uuid, Schemas.object_filename())
    assert get_in(meta, ["state", "examined"]) == "custom"
  end

  # ---- CX-mxxe / CX-hh70: casual examine hides freeform state; @dump shows it ----

  test "CX-hh70: `examine` does NOT leak the object's freeform state (puzzle answer key stays hidden)", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    altar_uuid = create_object(store, "altar")
    :ok = add_dir_entry(store, room_uuid, "altar.obj", altar_uuid)

    # Land a spoiler-y state key the way an interactable would (put_state).
    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "expect", "spark")|
    assert :ok = VerbSource.save_safe_verb(altar_uuid, "prime", body, [altar_uuid], store)
    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert :ok = Verbs.dispatch(Parser.parse("prime altar"), ctx)

    # Sanity: the state key really landed.
    assert get_in(raw_meta(store, altar_uuid, Schemas.object_filename()), ["state", "expect"]) ==
             "spark"

    # Casual examine shows the name but NOT the raw state block / answer key.
    assert {:reply, text} = Verbs.dispatch(Parser.parse("examine altar"), ctx)
    assert text =~ "altar"
    refute text =~ "State:"
    refute text =~ "expect"
    refute text =~ "spark"
  end

  test "CX-mxxe: `@dump <obj>` still surfaces freeform state for builders/debug", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    altar_uuid = create_object(store, "altar")
    :ok = add_dir_entry(store, room_uuid, "altar.obj", altar_uuid)

    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "expect", "spark")|
    assert :ok = VerbSource.save_safe_verb(altar_uuid, "prime", body, [altar_uuid], store)
    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert :ok = Verbs.dispatch(Parser.parse("prime altar"), ctx)

    # The raw-internals command DOES show state (the struct dump drops it — CX-hqk5 —
    # so this is the ONLY in-world inspection path once examine stops leaking it).
    assert {:reply, text} = Verbs.dispatch(Parser.parse("@dump altar"), ctx)
    assert text =~ "State:"
    assert text =~ "expect"
    assert text =~ "spark"
  end

  # ---- CX-2o9o: compile errors surface the real diagnostic ----

  test "CX-2o9o: a compile error surfaces the real diagnostic (undefined variable), not 'errors have been logged'", %{
    store: store,
    room_uuid: room_uuid
  } do
    idol_uuid = create_object(store, "idol")
    :ok = add_dir_entry(store, room_uuid, "idol.obj", idol_uuid)

    # Passes the allowlist (no disallowed CALL — it's a bare identifier), then
    # fails to COMPILE: mystery_variable is not in scope. Pre-fix the author got
    # only "cannot compile module ... (errors have been logged)".
    body = ~s|Commonplace.MUD.World.Facade.emit(world, mystery_variable)|
    assert {:error, {:compile_error, msg}} = VerbSource.save_safe_verb(idol_uuid, "boom", body, [idol_uuid], store)

    assert msg =~ "mystery_variable", "the real cause should name the undefined variable: #{msg}"
    refute msg =~ "errors have been logged", "the opaque log-pointer should be gone: #{msg}"
  end

  # ---- CX-cj3t.11: @verb resolves a multi-word object name ----

  test "CX-cj3t.11: `@verb <multi-word obj>:<verb>` resolves the multi-word target (enters the editor)", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    box_uuid = create_object(store, "brass strongbox")
    :ok = add_dir_entry(store, room_uuid, "brass strongbox.obj", box_uuid)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    # Pre-fix, `@verb` resolved <target> as a single token so a spaced name
    # ("brass strongbox") never matched — it errored instead of opening.
    result = Verbs.dispatch(Parser.parse("@verb brass strongbox:swing"), ctx)
    assert match?({:enter_editor, %{verb_name: "swing"}}, result),
           "multi-word @verb target should open the editor, got: #{inspect(result)}"
  end

  test "pin M2.2c (CX-z6ub): the `use` node BASELINE replies \"Nothing happens.\" on a fresh object", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    lever_uuid = create_object(store, "lever")
    :ok = add_dir_entry(store, room_uuid, "lever.obj", lever_uuid)

    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert {:reply, "Nothing happens."} = Verbs.dispatch(Parser.parse("use lever"), ctx)
  end

  test "pin M2.2d (CX-z6ub): a citizen's `use` override on the host FIRES instead of the node baseline", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    lever_uuid = create_object(store, "lever")
    :ok = add_dir_entry(store, room_uuid, "lever.obj", lever_uuid)

    body = ~s|Commonplace.MUD.World.Facade.put_state(world, "used", "yes")|
    assert :ok = VerbSource.save_safe_verb(lever_uuid, "use", body, [lever_uuid], store)

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    Verbs.dispatch(Parser.parse("use lever"), ctx)

    meta = raw_meta(store, lever_uuid, Schemas.object_filename())
    assert get_in(meta, ["state", "used"]) == "yes"
  end

  test "pin M2.2e (CX-z6ub): `search` baseline is reachable (plain no-note reply)", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    ctx = base_ctx(store, room_uuid, inventory_uuid)

    assert {:reply, "You search but find nothing of note."} =
             Verbs.dispatch(Parser.parse("search"), ctx)
  end

  test "pin M2.2f (CX-z6ub): `sit`/`stand` baselines reply and broadcast an emote-kind room action", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    player_uuid = UUID.uuid4()
    ctx = base_ctx(store, room_uuid, inventory_uuid, player_uuid: player_uuid)

    # A bystander subscribed to the room sees the emote-kind action; the actor
    # is filtered out (except: [player_uuid]) and gets only the {:reply}.
    Commonplace.MUD.Topics.subscribe_room(room_uuid)

    assert {:reply, "You sit down."} = Verbs.dispatch(Parser.parse("sit"), ctx)
    assert_receive {_topic, %{kind: :emote, who: "alice", text: "sits down.", except: [^player_uuid]}}

    assert {:reply, "You stand up."} = Verbs.dispatch(Parser.parse("stand"), ctx)
    assert_receive {_topic, %{kind: :emote, who: "alice", text: "stands up.", except: [^player_uuid]}}
  end

  test "pin M2.2g (CX-z6ub): `read` baseline reads state.text over description, both over nothing", %{
    store: store,
    room_uuid: room_uuid,
    inventory_uuid: inventory_uuid
  } do
    # A described sign with no state.text → reads its description.
    sign_uuid =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "sign", description: "Keep Out"}),
        store
      )
      |> then(fn {:ok, u} -> u end)

    :ok = add_dir_entry(store, room_uuid, "sign.obj", sign_uuid)

    ctx = base_ctx(store, room_uuid, inventory_uuid)
    assert {:reply, "The sign reads: Keep Out"} = Verbs.dispatch(Parser.parse("read sign"), ctx)
  end
end
