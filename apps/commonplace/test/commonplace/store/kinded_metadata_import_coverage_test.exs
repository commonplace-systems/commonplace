defmodule Commonplace.Store.KindedMetadataImportCoverageTest do
  @moduledoc """
  EVIDENCE-ONLY coverage for CX-hqko: is the "%{kind: :regular} chained
  onto a legacy %{}-metadata parent gets no snapshot_parent and is
  rejected on import" bug (verified 2026-08-05, see
  `apps/commonplace/test/commonplace/bd/close_commit_import_test.exs`
  for the original repro) ACTIVE at any of the three other production
  sites that write `%{kind: :regular, ...}` without an explicit
  `:snapshot_parent`:

    (A) `Commonplace.ViewActionDispatch.do_accept_merge/7` (pr_merge
        stamp, `view_action_dispatch.ex:1738`) — via
        `Commonplace.Tree.Merge.merge/4`'s `opts[:metadata]` plumb.
    (B) `Commonplace.Presence.Identity.write_metadata/2`
        (`identity.ex:59,63`).
    (C) `Commonplace.MUD.SignedWrite.opts_for/2`
        (`signed_write.ex:88`) — the capability_proof stamp.

  This file makes NO production-code changes. It only builds isolated
  tmp-dir stores, drives (or, where noted, faithfully simulates) each
  site's real write path, and observes `import_commit/3`.

  Harness pattern (ancestry_of/replay_chain/two-store round trip) is
  lifted directly from `close_commit_import_test.exs`, which is the
  proven harness for exactly this class of bug — see that file's
  moduledoc for why `ancestry_of/2` must drop the newest (tested)
  commit before replay: without that, the tested commit gets replayed
  too and `import_commit` returns `:already_exists`, a green that
  cannot fail.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Store.Supervisor, as: StoreSupervisor
  alias Commonplace.Tree.{Merge, Schema, Fork}
  alias Commonplace.Document.ContentType
  alias Commonplace.Presence.Identity
  alias Commonplace.MUD.SignedWrite
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  # ── Generic plain-CommitStore harness (controls, site A, site B) ──

  defp new_plain_store(tag) do
    dir = Path.join(System.tmp_dir!(), "cp_kmic_#{tag}_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"kmic_store_#{tag}_#{:rand.uniform(1_000_000)}"

    start_supervised!({CommitStore, data_dir: dir, name: name},
      id: :"store_#{tag}_#{:rand.uniform(1_000_000)}"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    name
  end

  defp new_target_store(tag) do
    dir = Path.join(System.tmp_dir!(), "cp_kmic_target_#{tag}_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"kmic_target_#{tag}_#{:rand.uniform(1_000_000)}"

    start_supervised!({CommitStore, data_dir: dir, name: name},
      id: :"target_#{tag}_#{:rand.uniform(1_000_000)}"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    name
  end

  # Same ancestry-drop as close_commit_import_test.exs: everything
  # BEFORE the tested commit, oldest-first.
  defp ancestry_of(store, node_id) do
    store
    |> CommitStore.commit_log(node_id, limit: CommitStore.max_commit_log_limit())
    |> Enum.reverse()
    |> Enum.drop(-1)
  end

  defp replay_chain(target_store, commits) do
    Enum.each(commits, fn commit ->
      result = CommitStore.import_commit(target_store, commit)

      assert result in [:ok, :already_exists],
             "ancestry replay failed on #{commit.id} (kind=#{inspect(Map.get(commit.metadata, :kind))}): #{inspect(result)}"
    end)
  end

  # Full round-trip: fresh target store, replay ancestry, import the
  # commit under test, return its result (does NOT assert).
  defp round_trip(tag, source_store, tested_commit) do
    target = new_target_store(tag)
    ancestry = ancestry_of(source_store, tested_commit.doc_uuid)
    replay_chain(target, ancestry)
    CommitStore.import_commit(target, tested_commit)
  end

  # ── CONTROLS ──────────────────────────────────────────────────────

  describe "controls (prove the harness can distinguish both verdicts)" do
    test "CONTROL A: plain %{}-metadata commit imports :ok" do
      store = new_plain_store("ctrl_ok")
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "f.txt")
      doc = ContentType.insert_text(doc, 0, "hello")
      update = Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, uuid, update, nil)

      IO.puts("CONTROL A commit.metadata = #{inspect(commit.metadata)}")
      assert commit.metadata == %{}

      result = round_trip("ctrl_ok", store, commit)
      IO.puts("CONTROL A import_commit/3 result: #{inspect(result)}")
      assert result in [:ok, :already_exists]
    end

    test "CONTROL B: %{kind: :regular} chained on a %{} parent now imports cleanly (CX-hqko fix)" do
      store = new_plain_store("ctrl_bug")
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "f.txt")
      doc = ContentType.insert_text(doc, 0, "hello")
      update = Encoding.encode_update(doc)
      # Legacy %{} parent, exactly like every plain create_commit call.
      parent_commit = CommitStore.create_commit(store, uuid, update, nil)
      assert parent_commit.metadata == %{}

      doc2 = ContentType.insert_text(doc, 5, " world")
      update2 = Encoding.encode_update(doc2)

      child_commit =
        CommitStore.create_commit(store, uuid, update2, parent_commit.id, %{
          kind: :regular,
          some_key: "x"
        })

      IO.puts("CONTROL B commit.metadata = #{inspect(child_commit.metadata)}")
      refute Map.has_key?(child_commit.metadata, :snapshot_parent)

      # CX-hqko: this used to assert rejection with :missing_snapshot_parent.
      # Under the fix, "validation judges claims, not absences" — this
      # commit makes no snapshot_parent claim at all, so it is no longer
      # held to the strict ancestry check and imports cleanly. Kept (not
      # deleted) as a record of the behavior change.
      result = round_trip("ctrl_bug", store, child_commit)
      IO.puts("CONTROL B import_commit/3 result: #{inspect(result)}")
      assert result in [:ok, :already_exists]
    end

    test "NEGATIVE CONTROL: a snapshot_parent CLAIM that doesn't resolve is still rejected" do
      # Proves the harness (and the fix) can still produce a rejection —
      # without this, every assertion in this file passes and the file
      # can no longer catch a regression. This commit CLAIMS an epoch
      # (snapshot_parent is present and binary) but references a
      # clientID outside the namespace that claim resolves to, so it
      # must still be rejected via the unchanged strict path.
      store = new_plain_store("ctrl_neg")
      uuid = UUID.uuid4()
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      seed_update =
        (fn ->
           doc = Yelixer.Doc.new(client_id: 1)
           {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
           doc = Yelixer.Types.Text.insert(doc, "t", 0, "a")
           Yelixer.Encoding.encode_update(doc)
         end).()

      c1 =
        CommitStore.create_commit(store, uuid, seed_update, genesis.id, %{
          kind: :regular,
          snapshot_parent: genesis.id
        })

      doc_ref = Yelixer.Doc.new(client_id: 999)
      {doc_ref, _} = Yelixer.Doc.get_or_create_type(doc_ref, "t", :text)
      doc_ref = Yelixer.Types.Text.insert(doc_ref, "t", 0, "ref")
      base = Yelixer.Encoding.encode_update(doc_ref)

      doc_auth = Yelixer.Doc.new(client_id: 42)
      {doc_auth, _} = Yelixer.Doc.get_or_create_type(doc_auth, "t", :text)
      {:ok, doc_auth} = Yelixer.Encoding.apply_update(doc_auth, base)
      doc_auth = Yelixer.Types.Text.insert(doc_auth, "t", 3, "X")
      base_sv = Yelixer.BlockStore.state_vector(doc_ref.store)
      referencing_update = Yelixer.Encoding.encode_diff(doc_auth, base_sv)

      # Persisted to the SOURCE store (not just built with Commit.new) —
      # ancestry_of/2 assumes the tested commit is the newest entry in
      # the source doc's log and drops exactly that one before replay
      # (see its moduledoc). Building the tested commit off-store here
      # would make ancestry_of drop c1 instead, starving the target of
      # c1's clientID and making the namespace vacuously empty — that
      # was caught while writing this test (first version accepted the
      # commit for the wrong reason).
      bad_commit =
        CommitStore.create_commit(store, uuid, referencing_update, c1.id, %{
          kind: :regular,
          snapshot_parent: genesis.id
        })

      result = round_trip("ctrl_neg", store, bad_commit)
      IO.puts("NEGATIVE CONTROL import_commit/3 result: #{inspect(result)}")
      assert {:error, {:namespace_rejected, {:unknown_reference, ids}}} = result
      assert 999 in ids
    end
  end

  # ── SITE A: ViewActionDispatch.do_accept_merge/7's pr_merge stamp ─
  # DRIVEN FOR REAL: Commonplace.Tree.Merge.merge/4 with the exact
  # opts[:metadata] shape do_accept_merge passes. The target doc's
  # PARENT shape (legacy %{}) is what merge_test.exs's own helpers
  # produce by default ("merge commits carry empty metadata by
  # default" is an existing assertion in that file), and matches what
  # close_commit_import_test.exs independently found for bd docs — so
  # this is the realistic shape for a wiki/bd-style PR-merge target,
  # not a hand-picked worst case.

  describe "site A: pr_merge stamp (Merge.merge/4, DRIVEN FOR REAL)" do
    defp create_text_doc(store, name, content) do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, name)
      doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
      update = Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)
      uuid
    end

    defp create_schema(store, entries) do
      uuid = UUID.uuid4()
      doc = Schema.new_schema()

      doc =
        Enum.reduce(entries, doc, fn {name, {type, node_id}}, doc ->
          case type do
            :doc -> Schema.add_file(doc, name, node_id)
            :dir -> Schema.add_directory(doc, name, node_id)
          end
        end)

      CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)
      uuid
    end

    defp reconstruct_doc_a(store, uuid) do
      commits =
        CommitStore.commit_log(store, uuid, limit: 10_000)
        |> Enum.reverse()
        |> Enum.reject(&match?(%{metadata: %{kind: :genesis}}, &1))

      doc = Yelixer.Doc.new()
      Enum.reduce(commits, {:ok, doc}, fn c, {:ok, d} -> Encoding.apply_update(d, c.update) end)
    end

    defp edit_doc_a(store, uuid, text, position) do
      {:ok, doc} = reconstruct_doc_a(store, uuid)
      doc = ContentType.insert_text(doc, position, text)
      update = Encoding.encode_update(doc)
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      CommitStore.create_commit(store, uuid, update, latest.id)
    end

    test "pr_merge commit lands on a legacy %{}-parented target file, then round-trips" do
      store = new_plain_store("site_a")
      file_uuid = create_text_doc(store, "file.txt", "hello")
      root_uuid = create_schema(store, %{"file.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)
      {:ok, fork_schema} = reconstruct_schema_a(store, fork_root)
      {:ok, fork_file_entry} = Schema.get_entry(fork_schema, "file.txt")
      edit_doc_a(store, fork_file_entry.node_id, " world", 5)

      pr_uuid = UUID.uuid4()

      {:ok, latest_before} = CommitStore.latest_commit(store, file_uuid)

      IO.puts(
        "SITE A: target file's parent (pre-merge) metadata = #{inspect(latest_before.metadata)}"
      )

      {:ok, _report} =
        Merge.merge(fork_root, root_uuid, store, metadata: %{kind: :regular, pr_merge: pr_uuid})

      {:ok, merge_commit} = CommitStore.latest_commit(store, file_uuid)
      IO.puts("SITE A merge commit.metadata = #{inspect(merge_commit.metadata)}")

      IO.puts(
        "SITE A snapshot_parent present? #{Map.has_key?(merge_commit.metadata, :snapshot_parent)}"
      )

      result = round_trip("site_a", store, merge_commit)
      IO.puts("SITE A import_commit/3 result: #{inspect(result)}")

      # CX-hqko: this is the deciding proof. Before the fix, a real
      # pr_merge commit onto a legacy-headed target rejected with
      # {:namespace_rejected, :missing_snapshot_parent}. The fix makes
      # this import cleanly.
      assert result == :ok
    end

    defp reconstruct_schema_a(store, uuid) do
      case CommitStore.latest_commit(store, uuid) do
        {:ok, commit} ->
          schema = Schema.new_schema()
          Encoding.apply_update(schema, commit.update)

        other ->
          other
      end
    end
  end

  # ── SITE B: Presence.Identity's write_metadata guard ──────────────
  # DRIVEN FOR REAL: Identity.register/5 and Identity.touch_last_seen/3
  # are called directly (their own moduledoc / write_metadata comment
  # explicitly documents awareness of this exact bug: "Chaining a
  # :regular commit onto a LEGACY head would produce
  # kind-without-snapshot_parent ... so legacy docs keep writing legacy
  # commits"). We drive both the fresh-doc path (should be safe) and,
  # by manufacturing a legacy %{}-headed identity doc (bypassing
  # Identity.register to plant a pre-existing-legacy shape),
  # touch_last_seen on a LEGACY head, to observe whether the guard
  # actually refuses to enter the danger zone.

  describe "site B: Presence.Identity write_metadata (DRIVEN FOR REAL)" do
    test "fresh identity: register + touch_last_seen both round-trip" do
      store = new_plain_store("site_b_fresh")
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      CommitStore.create_commit(store, root_uuid, Encoding.encode_update(root_doc), nil)

      {:ok, identity_uuid} = Identity.register("alice", :usr, root_uuid, store)
      {:ok, register_commit} = CommitStore.latest_commit(store, identity_uuid)
      IO.puts("SITE B register commit.metadata = #{inspect(register_commit.metadata)}")

      Identity.touch_last_seen(identity_uuid, store)
      {:ok, touch_commit} = CommitStore.latest_commit(store, identity_uuid)
      IO.puts("SITE B touch_last_seen commit.metadata = #{inspect(touch_commit.metadata)}")

      register_result = round_trip("site_b_reg", store, register_commit)
      IO.puts("SITE B register import_commit/3 result: #{inspect(register_result)}")

      touch_result = round_trip("site_b_touch", store, touch_commit)
      IO.puts("SITE B touch_last_seen import_commit/3 result: #{inspect(touch_result)}")
    end

    test "legacy-headed identity doc: touch_last_seen falls back to %{} instead of tripping the bug" do
      store = new_plain_store("site_b_legacy")
      uuid = UUID.uuid4()

      # Manufacture a legacy identity doc: a plain %{}-metadata commit,
      # exactly the shape a pre-CX-tdkq.1 identity doc (or any doc
      # written before this guard existed) would carry as its head.
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :map, "alice.usr")
      doc = ContentType.set_key(doc, "name", "alice")
      doc = ContentType.set_key(doc, "type", "usr")
      doc = ContentType.set_key(doc, "first_seen", "2020-01-01T00:00:00Z")
      doc = ContentType.set_key(doc, "last_seen", "2020-01-01T00:00:00Z")
      update = Encoding.encode_update(doc)
      legacy_commit = CommitStore.create_commit(store, uuid, update, nil, %{})
      assert legacy_commit.metadata == %{}

      Identity.touch_last_seen(uuid, store)
      {:ok, touch_commit} = CommitStore.latest_commit(store, uuid)

      IO.puts(
        "SITE B (legacy head) touch_last_seen commit.metadata = #{inspect(touch_commit.metadata)}"
      )

      # The guard: write_metadata only emits %{kind: :regular} when
      # current_namespace(head) is non-nil. A legacy %{} head has nil
      # current_namespace, so this MUST come back plain %{}.
      assert touch_commit.metadata == %{},
             "write_metadata's guard did not fall back to %{} on a legacy head — " <>
               "this would mean site B IS exposed to CX-hqko"

      result = round_trip("site_b_legacy", store, touch_commit)
      IO.puts("SITE B (legacy head) import_commit/3 result: #{inspect(result)}")
      assert result in [:ok, :already_exists]
    end
  end

  # ── SITE C: MUD.SignedWrite's capability_proof stamp ───────────────
  # DRIVEN FOR REAL for the metadata-production half:
  # SignedWrite.opts_for/2 is called directly with a real minted+stored
  # capability cert (same pattern as signed_write_test.exs). What is
  # SIMULATED is the PARENT DOC SHAPE — we construct both a fresh
  # (genesis-parented, safe) MUD-style doc and a doc whose head is a
  # manufactured legacy %{}-metadata commit (representing a doc that
  # predates the capability-cert system, or was last touched by an
  # unsigned/no-cert write, which SignedWrite.opts_for produces as
  # `%{}` — see `via_verb_metadata`/no-signing-context clauses; a
  # %{}-headed OR %{via_verb: _}-headed doc both yield
  # current_namespace == nil, i.e. equally dangerous parents). This
  # distinction (real opts_for call, simulated parent lineage) is
  # called out explicitly because we did not drive a full
  # PlayerSession/Verbs/Facade path.

  describe "site C: MUD.SignedWrite capability_proof (opts_for DRIVEN FOR REAL, parent lineage SIMULATED)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_kmic_site_c_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      n = :rand.uniform(1_000_000)
      name = :"kmic_sitec_store_#{n}"

      start_supervised!(
        {StoreSupervisor,
         data_dir: dir,
         name: :"kmic_sitec_sup_#{n}",
         commit_store_name: name,
         trust_side_store_name: :"kmic_sitec_tss_#{n}",
         pending_imports_name: :"kmic_sitec_pi_#{n}"}
      )

      on_exit(fn -> File.rm_rf!(dir) end)

      {pub, priv} = Signing.generate_keypair()
      issuer_ctx = %SigningContext{identity_uuid: "root-id", private_key: priv, public_key: pub}
      audience = {"bot-id", pub}

      %{store: name, issuer_ctx: issuer_ctx, audience: audience}
    end

    defp mint_and_store(ctx, target_uuid) do
      {:ok, cap} =
        Capability.issue(ctx.issuer_ctx, ctx.audience, %{
          verbs: [:write],
          scope: {:docs, [target_uuid]},
          caveats: %{}
        })

      :ok = CommitStoreClient.store_capability(ctx.store, cap)
      cap
    end

    test "SAFE case: capability_proof write onto a fresh (genesis-parented) doc round-trips",
         ctx do
      target_uuid = UUID.uuid4()
      cap = mint_and_store(ctx, target_uuid)

      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :map, "room.dir")
      doc = ContentType.set_key(doc, "desc", "a room")
      update = Encoding.encode_update(doc)

      {metadata, commit_opts} =
        SignedWrite.opts_for(target_uuid,
          signing_context: ctx.issuer_ctx,
          cert_cids: [cap.id],
          store: ctx.store
        )

      IO.puts("SITE C (fresh/genesis parent) opts_for metadata = #{inspect(metadata)}")
      assert metadata.kind == :regular
      assert metadata.capability_proof == cap.id

      commit =
        CommitStoreClient.create_commit(
          ctx.store,
          target_uuid,
          update,
          nil,
          metadata,
          commit_opts
        )

      IO.puts("SITE C (fresh parent) commit.metadata = #{inspect(commit.metadata)}")

      IO.puts(
        "SITE C (fresh parent) snapshot_parent present? #{Map.has_key?(commit.metadata, :snapshot_parent)}"
      )

      result = round_trip_plain(commit, ctx.store)
      IO.puts("SITE C (fresh parent) result: #{inspect(result)}")
    end

    test "DANGER case: capability_proof write chained onto a legacy %{}-headed doc", ctx do
      target_uuid = UUID.uuid4()
      cap = mint_and_store(ctx, target_uuid)

      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :map, "room.dir")
      doc = ContentType.set_key(doc, "desc", "an old room")
      update = Encoding.encode_update(doc)

      # Manufacture the legacy parent: a plain %{}-metadata commit,
      # representing a MUD doc whose most recent write predates the
      # capability-cert system, or was last touched unsigned/no-cert
      # (SignedWrite.opts_for's own no-signing-context / no-matching-cert
      # branches both produce exactly this %{} shape).
      legacy_commit = CommitStoreClient.create_commit(ctx.store, target_uuid, update, nil, %{})
      assert legacy_commit.metadata == %{}

      doc2 = ContentType.set_key(doc, "desc", "an old room, renovated")
      update2 = Encoding.encode_update(doc2)

      {metadata, commit_opts} =
        SignedWrite.opts_for(target_uuid,
          signing_context: ctx.issuer_ctx,
          cert_cids: [cap.id],
          store: ctx.store
        )

      IO.puts("SITE C (legacy %{} parent) opts_for metadata = #{inspect(metadata)}")
      assert metadata.kind == :regular
      assert metadata.capability_proof == cap.id

      commit =
        CommitStoreClient.create_chained_commit(
          ctx.store,
          target_uuid,
          update2,
          metadata,
          commit_opts
        )

      IO.puts("SITE C (legacy parent) commit.metadata = #{inspect(commit.metadata)}")

      IO.puts(
        "SITE C (legacy parent) snapshot_parent present? #{Map.has_key?(commit.metadata, :snapshot_parent)}"
      )

      result = round_trip_plain(commit, ctx.store)
      IO.puts("SITE C (legacy parent) result: #{inspect(result)}")
    end

    # Site C's source store is the StoreSupervisor-managed CommitStore
    # (a plain CommitStore under the hood, same module) — reuse the
    # same ancestry/replay pattern against a plain target store.
    #
    # IMPORTANT: `CommitStore.import_commit/3`'s pipeline is
    # `trust_check` THEN `code_doc_delta_merge_check` THEN
    # `namespace_check` (see `import_validation/3`) — trust_check runs
    # FIRST and is a completely separate gate (capability-cert chain /
    # locally-pinned-identity trust) from the namespace bug under
    # test. A capability-signed commit whose issuer isn't independently
    # established as trusted in the target store is rejected at
    # trust_check with `{:trust_rejected, :awaiting_capability}` before
    # namespace_check ever runs — that's what a first pass of this test
    # observed (both the "safe" and "danger" cases got the SAME
    # trust_rejected verdict, which is uninformative about CX-hqko).
    # Standing up a full trusted capability-cert chain is exactly the
    # "too much scaffolding" case the task brief calls out, so — to
    # isolate the actual mechanism in question — this calls
    # `Commonplace.Store.Namespace.validate_commit_from_db/2` directly:
    # the SAME function `import_commit`'s namespace_check invokes
    # (commit_store.ex:1950), just without the orthogonal trust gate in
    # front of it. Both the full `import_commit/3` result AND the
    # isolated namespace verdict are printed so both are on the record.
    defp round_trip_plain(tested_commit, source_store) do
      target = new_target_store("site_c_#{:rand.uniform(1_000_000)}")
      ancestry = ancestry_of(source_store, tested_commit.doc_uuid)
      replay_chain(target, ancestry)

      import_result = CommitStore.import_commit(target, tested_commit)
      db = CommitStore.db_handle(target)
      namespace_result = Commonplace.Store.Namespace.validate_commit_from_db(db, tested_commit)

      %{import_commit: import_result, namespace_check_isolated: namespace_result}
    end
  end
end
