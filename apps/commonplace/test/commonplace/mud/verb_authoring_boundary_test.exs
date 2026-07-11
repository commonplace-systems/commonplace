defmodule Commonplace.MUD.VerbAuthoringBoundaryTest do
  @moduledoc """
  The verb-authoring trust boundary UNDER :enforce (CX-fogy — the "build your own
  world" creative payoff, design @9398646 §2).

  As of CX-fogy, citizenship grants a THIRD cert — `{:subtree,home}[:define_verb]`
  — so a citizen CAN author SANDBOXED safe-verbs anywhere in their own home. The
  guard this pins is the (still load-bearing) boundary AROUND that grant:

    1. A citizen holding `{:subtree,home}[:define_verb]` CAN save a sandboxed
       verb in their own home (the feature).
    2. A principal holding only `{:subtree,home}[:write]` (NO `:define_verb`)
       CANNOT — `:write` alone does not authorize verb-authoring (the grant is a
       distinct, separately-scoped capability; this is the regression guard that
       CX-fogy did NOT widen `:write` into authoring authority).
    3. RAW engine code (`:execute` / Gate-B) stays node-only: the citizen's
       `:define_verb` cert does NOT satisfy `:execute`, so raw `.elx` authoring is
       still denied — the sandbox is the RCE containment, Gate-B is untouched.

  If a future change ever lets a `:write`-only principal author (test 2 goes
  green-on-save) or lets a citizen's `:define_verb` mint raw executable code
  (test 3 flips), it fails here — surfacing an RCE-boundary regression.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.MUD.{Citizenship, VerbSource}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_verbchar_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"verbchar_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"verbchar_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"verbchar_tss_#{n}",
       pending_imports_name: :"verbchar_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      knob: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {k, v} <- [data_dir: old.data_dir, trust: old.trust, local_write_gate: old.knob] do
        if v == nil, do: Application.delete_env(:commonplace, k), else: Application.put_env(:commonplace, k, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(Schema.new_schema()), nil, %{}, signing_context: node_ctx)

    # A full CITIZEN — Citizenship.ensure now grants the {:subtree,home}[:define_verb]
    # authoring cert (CX-fogy) alongside the [:write] + {:presence} certs.
    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    citizen = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}
    {:ok, %{cert_cids: cids, home_room_uuid: home}} = Citizenship.ensure(pid, pub, "builder", root, store)

    # A SECOND principal holding ONLY a {:subtree,home}[:write] cert over the same
    # home — NO :define_verb. The regression guard: :write alone must NOT authorize
    # verb-authoring (CX-fogy is a distinct grant, not a widening of :write).
    {wpub, wpriv} = Signing.generate_keypair()
    wid = UUID.uuid4()
    writer = %SigningContext{identity_uuid: wid, public_key: wpub, private_key: wpriv}
    {:ok, wcap} =
      Capability.issue(node_ctx, {wid, wpub}, %{verbs: [:write], scope: {:subtree, home}, caveats: %{}}, nil, store: store)
    :ok = CommitStoreClient.store_capability(store, wcap)

    %{store: store, root: root, home: home, citizen: citizen, cids: cids,
      writer: writer, writer_cids: [wcap.id], node_ctx: node_ctx}
  end

  # bare-literal body: passes the safe-verb lint (no calls) so the tests isolate
  # the AUTHORITY axis (define_verb vs write vs node), not the allowlist. (The lint
  # runs BEFORE the write, so a disallowed call would mask the trust result.)
  @body "\"tick\""

  test "CX-fogy: a citizen holding {:subtree,home}[:define_verb] CAN save a sandboxed verb in their OWN home", %{store: store, home: home, citizen: citizen, cids: cids} do
    result =
      VerbSource.save_safe_verb(home, "tick", @body, [home], store,
        signing_context: citizen,
        cert_cids: cids,
        signer_id: nil
      )

    assert result == :ok
  end

  test "BOUNDARY: a {:write}-only principal (no :define_verb) CANNOT save a verb — :write alone is insufficient", %{store: store, home: home, writer: writer, writer_cids: writer_cids} do
    result =
      VerbSource.save_safe_verb(home, "tick", @body, [home], store,
        signing_context: writer,
        cert_cids: writer_cids,
        signer_id: nil
      )

    # Pin the SHAPE — a bare {:error, _} would also match a lint/compile fault,
    # which is NOT the boundary we're guarding.
    assert {:error, {:trust_rejected, _}} = result
  end

  test "the NODE (execute authority) CAN save the same verb — authority, not a broken path", %{store: store, home: home, node_ctx: node_ctx} do
    result =
      VerbSource.save_safe_verb(home, "tick", @body, [home], store,
        signing_context: node_ctx,
        cert_cids: []
      )

    assert result == :ok
  end

  test "BOUNDARY (Gate-B untouched): a citizen's :define_verb cert does NOT authorize RAW .elx code", %{store: store, home: home, citizen: citizen, cids: cids} do
    # The RAW-code lane (VerbSource.save_verb → <name>.elx, unsandboxed) is gated on
    # :execute / Gate-B. A citizen holds :define_verb (sandboxed lane) but NOT
    # :execute, so raw-code authoring stays denied — the RCE wall is untouched.
    result =
      VerbSource.save_verb(home, "rawtick", @body, store,
        signing_context: citizen,
        cert_cids: cids,
        signer_id: nil
      )

    assert {:error, {:trust_rejected, _}} = result
  end

  # ---- the @verb editor's upfront editable/PREVIEW flag reflects the same gate ----
  defp verb_ctx(store, home, sctx, cids),
    do: %{
      store: store,
      player_name: "builder",
      root_uuid: nil,
      current_room_uuid: home,
      inventory_uuid: nil,
      signing_context: sctx,
      cert_cids: cids,
      signer_id: nil
    }

  test "CX-fogy: a citizen with :define_verb opening @verb gets the EDITABLE editor (editable: true)", %{store: store, home: home, citizen: citizen, cids: cids} do
    cmd = Commonplace.MUD.Parser.parse("@verb here:tick")
    assert {:enter_editor, %{editable: true}} = Commonplace.MUD.Verbs.dispatch(cmd, verb_ctx(store, home, citizen, cids))
  end

  test "the NODE opening @verb gets the editable editor (editable: true)", %{store: store, home: home, node_ctx: node_ctx} do
    cmd = Commonplace.MUD.Parser.parse("@verb here:tick")
    assert {:enter_editor, %{editable: true}} = Commonplace.MUD.Verbs.dispatch(cmd, verb_ctx(store, home, node_ctx, []))
  end

  test "BOUNDARY: a {:write}-only principal opening @verb gets PREVIEW (editable: false)", %{store: store, home: home, writer: writer, writer_cids: writer_cids} do
    cmd = Commonplace.MUD.Parser.parse("@verb here:tick")
    assert {:enter_editor, %{editable: false}} = Commonplace.MUD.Verbs.dispatch(cmd, verb_ctx(store, home, writer, writer_cids))
  end

  # The PREVIEW must carry the REAL existing source read-only for a caller who
  # can't author: node authors a verb, then the {:write}-only principal's @verb
  # open returns editable:false WITH the current source populated.
  test "a {:write}-only principal's preview of an EXISTING verb carries its source read-only", %{store: store, home: home, writer: writer, writer_cids: writer_cids, node_ctx: node_ctx} do
    :ok = VerbSource.save_safe_verb(home, "glow", "\"glimmer\"", [home], store, signing_context: node_ctx, cert_cids: [])

    cmd = Commonplace.MUD.Parser.parse("@verb here:glow")
    assert {:enter_editor, %{editable: false, current: current}} =
             Commonplace.MUD.Verbs.dispatch(cmd, verb_ctx(store, home, writer, writer_cids))

    assert current =~ "glimmer"
  end

  # ---- CX-fogy L3 (OPTION 2): the verb still DISPATCHES + the cross-verify ----

  test "CX-fogy L3: a citizen-saved verb still RESOLVES + COMPILES, and its verbs/ dir is zoned to the host (despite the __verbs.json meta child)", %{store: store, home: home, citizen: citizen, cids: cids} do
    :ok =
      VerbSource.save_safe_verb(home, "tick", @body, [home], store,
        signing_context: citizen,
        cert_cids: cids,
        signer_id: nil
      )

    # The verbs/ dir is now a ZONED child (`ChildMutation.create_zoned_child`)
    # carrying a `__verbs.json` zone-meta child. That `__`-prefixed meta must be
    # INERT to verb resolution — the verb still resolves + compiles (dispatch is
    # unaffected). If a future change let the meta child shadow the lookup, this
    # goes :not_found.
    assert {:ok, source_uuid} = VerbSource.find_safe_source(home, "tick", store)
    assert is_binary(source_uuid)
    assert {:ok, _module} = VerbSource.compile_safe_verb(home, "tick", [home], store)

    # The cross-verify anchor: the verbs/ dir carries the host's OWN zone, so a
    # citizen's {:subtree,home} cert carves both the dir link AND the verb
    # entry-add. This is what binds a verb to a host the author could write.
    {:ok, home_schema} = Commonplace.MUD.Schemas.load_dir_schema(home, store)
    {:ok, %Schema.Entry{node_id: verbs_uuid}} = Schema.get_entry(home_schema, "verbs")
    assert Commonplace.Trust.doc_zone(verbs_uuid, store) == Commonplace.Trust.doc_zone(home, store)
    refute is_nil(Commonplace.Trust.doc_zone(verbs_uuid, store))
  end

  test "BOUNDARY (cross-verify): a citizen CANNOT author a verb on a FOREIGN host — the verbs/ entry-add fails the :write carve", %{store: store, root: root, citizen: citizen, cids: cids} do
    # A SECOND citizen's home — a distinct zone the first citizen's
    # {:subtree,home1} cert does NOT cover.
    {vpub, _vpriv} = Signing.generate_keypair()
    vid = UUID.uuid4()
    {:ok, %{home_room_uuid: victim_home}} = Citizenship.ensure(vid, vpub, "victim", root, store)

    # citizen (holding only {:subtree, home1}) tries to author into victim_home.
    # The verbs/ dir link (and, were it to exist, the verb entry-add) is a :write
    # to a dir zoned to victim_home — a zone the citizen's cert can't carve → deny.
    result =
      VerbSource.save_safe_verb(victim_home, "sneak", @body, [victim_home], store,
        signing_context: citizen,
        cert_cids: cids,
        signer_id: nil
      )

    assert {:error, _} = result
    # Nothing landed: the foreign host has no such verb.
    assert :not_found = VerbSource.find_safe_source(victim_home, "sneak", store)
  end
end
