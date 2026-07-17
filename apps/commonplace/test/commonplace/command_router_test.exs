defmodule Commonplace.CommandRouterTest do
  use ExUnit.Case, async: false

  alias Commonplace.CommandRouter
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Dataflow.Magenta

  @command_topic "__commands"

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cmdrouter_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"cmdrouter_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  defp start_router(ctx, name \\ nil) do
    name = name || :"cmdrouter_#{:rand.uniform(1_000_000)}"
    {:ok, pid} = CommandRouter.start_link(store: ctx.store, name: name)
    on_exit(fn -> if Process.alive?(pid), do: (try do GenServer.stop(pid) catch (:exit, _ -> :ok) end) end)
    {pid, name}
  end

  defp create_leaf_doc(ctx, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = Commonplace.Document.ContentType.create(doc, :text, "doc.txt")
    doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(ctx.store, uuid, update, nil)
    uuid
  end

  describe "fork" do
    test "returns a new UUID for a valid source", ctx do
      {_pid, name} = start_router(ctx)

      assert {:ok, new_uuid} = CommandRouter.fork(name, ctx.root)
      assert is_binary(new_uuid)
      assert new_uuid != ctx.root
    end

    test "broadcasts command.initiated then command.completed on magenta", ctx do
      {_pid, name} = start_router(ctx)
      Magenta.subscribe(@command_topic)

      assert {:ok, new_uuid} = CommandRouter.fork(name, ctx.root)

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.initiated", payload: init}}, 500
      assert init["verb"] == "fork"
      assert init["args"]["source_uuid"] == ctx.root
      assert is_binary(init["command_id"])

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.completed", payload: done}}, 500
      assert done["verb"] == "fork"
      assert done["command_id"] == init["command_id"]
      assert done["result"]["new_uuid"] == new_uuid
      assert is_integer(done["duration_ms"])
    end

    # CX-kqz3: rapid fork retries on the same source piled up at
    # CommandRouter under MCP load (round 16 v1), saturated CommitStore,
    # starved net_kernel's heartbeat, and the escript declared serve
    # :nodedown. Async fork + per-source in-flight set short-circuits
    # the retry storm: a second fork of an in-flight source returns
    # immediately with `{:error, :fork_in_progress}` instead of joining
    # the queue.
    #
    # Test injects state directly via :sys.replace_state instead of
    # racing on real fork timing — fork on an empty root is microsecond-
    # fast and would complete before any reasonable Process.sleep, making
    # the test flaky. The dedup logic itself is what matters.
    test "in-flight set rejects duplicate fork of same source (CX-kqz3)", ctx do
      {pid, name} = start_router(ctx)

      :sys.replace_state(pid, fn state ->
        %{state | in_flight_forks: MapSet.put(state.in_flight_forks, ctx.root)}
      end)

      assert {:error, :fork_in_progress} = CommandRouter.fork(name, ctx.root)
    end

    test "in-flight set is cleared after fork completes (CX-kqz3)", ctx do
      {pid, name} = start_router(ctx)

      assert {:ok, _new_uuid} = CommandRouter.fork(name, ctx.root)

      state = :sys.get_state(pid)
      refute MapSet.member?(state.in_flight_forks, ctx.root),
             "in_flight_forks should be empty after fork completion, got: #{inspect(state.in_flight_forks)}"
    end

    test "concurrent forks of different sources both succeed (CX-kqz3)", ctx do
      {_pid, name} = start_router(ctx)

      # Two separate roots, both fork-able concurrently.
      other_root = UUID.uuid4()
      other_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(other_doc)
      CommitStore.create_commit(ctx.store, other_root, update, nil)

      first = Task.async(fn -> CommandRouter.fork(name, ctx.root) end)
      second = Task.async(fn -> CommandRouter.fork(name, other_root) end)

      assert {:ok, _} = Task.await(first, 5_000)
      assert {:ok, _} = Task.await(second, 5_000)
    end

    test "after a fork completes, the same source can be forked again (CX-kqz3)",
         ctx do
      {_pid, name} = start_router(ctx)

      assert {:ok, _first} = CommandRouter.fork(name, ctx.root)
      assert {:ok, _second} = CommandRouter.fork(name, ctx.root)
    end
  end

  describe "fork/3 signing plumb (CX-k20z-adjacent, intra-repo-PR spec §7.3c)" do
    # Mirrors `Commonplace.Tree.MergeTest`'s "merge/4 signing plumb"
    # discipline (§7.1): build the fork fixture FIRST under the default
    # permissive config, THEN flip to strict trust +
    # `local_write_gate: :enforce` for the fork call under test, so
    # fixture setup writes aren't themselves gated.
    setup ctx do
      old_data_dir = Application.get_env(:commonplace, :data_dir)
      old_trust = Application.get_env(:commonplace, :trust)
      old_knob = Application.get_env(:commonplace, :local_write_gate)

      node_dir =
        Path.join(System.tmp_dir!(), "cp_cmdrouter_fork_test_node_#{:rand.uniform(1_000_000_000)}")

      File.mkdir_p!(node_dir)
      Application.put_env(:commonplace, :data_dir, node_dir)

      {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()

      node_signer_id =
        Commonplace.Crypto.Signing.signer_id(node_ctx.identity_uuid, node_ctx.public_key)

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      Application.put_env(:commonplace, :local_write_gate, :enforce)

      on_exit(fn ->
        # CX-c93b hygiene: restore :data_dir to the test-config default
        # ("tmp/test_data") rather than delete_env when it was nil — a
        # deleted :data_dir surfaces as literal `nil` to a later file's
        # `Trust.config_from_file` -> `Path.join(nil, "trust.json")` crash
        # (the seed-dependent contamination class). This fixture's own
        # nil-safe restore keeps it from PROPAGATING an already-nil value;
        # it doesn't fix the legacy originators (that's CX-c93b's deferred
        # sweep), but a NEW fixture shouldn't add another propagator.
        Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

        case old_trust do
          nil -> Application.delete_env(:commonplace, :trust)
          v -> Application.put_env(:commonplace, :trust, v)
        end

        case old_knob do
          nil -> Application.delete_env(:commonplace, :local_write_gate)
          v -> Application.put_env(:commonplace, :local_write_gate, v)
        end

        File.rm_rf!(node_dir)
      end)

      Map.merge(ctx, %{node_ctx: node_ctx, node_signer_id: node_signer_id})
    end

    test "fork/2 (no opts) under enforce — the forked doc does NOT land", ctx do
      {_pid, name} = start_router(ctx)

      assert {:ok, new_uuid} = CommandRouter.fork(name, ctx.root)

      # Unsigned genesis-adjacent commit is gate-rejected; nothing was
      # persisted under the new UUID.
      assert CommitStore.latest_commit(ctx.store, new_uuid) == :none
    end

    test "fork/3 with signing_context under enforce — the forked doc LANDS, signed by the node",
         ctx do
      {_pid, name} = start_router(ctx)

      assert {:ok, new_uuid} = CommandRouter.fork(name, ctx.root, signing_context: ctx.node_ctx)

      assert {:ok, %Commonplace.Store.Commit{signer_id: signer}} =
               CommitStore.latest_commit(ctx.store, new_uuid)

      assert signer == ctx.node_signer_id
    end
  end

  describe "merge" do
    test "returns an {:ok, merge_report_summary} tuple", ctx do
      {_pid, name} = start_router(ctx)

      source = create_leaf_doc(ctx, "source content")
      target = create_leaf_doc(ctx, "target content")

      assert {:ok, summary} = CommandRouter.merge(name, source, target)
      assert is_map(summary)
      assert Map.has_key?(summary, "merged_count")
      assert Map.has_key?(summary, "conflict_count")
    end

    test "broadcasts command.initiated and command.completed on magenta", ctx do
      {_pid, name} = start_router(ctx)
      Magenta.subscribe(@command_topic)

      source = create_leaf_doc(ctx, "source content")
      target = create_leaf_doc(ctx, "target content")

      assert {:ok, _} = CommandRouter.merge(name, source, target)

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.initiated", payload: init}}, 500
      assert init["verb"] == "merge"
      assert init["args"]["source_uuid"] == source
      assert init["args"]["target_uuid"] == target

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.completed", payload: done}}, 500
      assert done["verb"] == "merge"
    end
  end

  describe "write" do
    test "applies a smart merge of new content onto an existing text doc", ctx do
      {_pid, name} = start_router(ctx)

      uuid = create_leaf_doc(ctx, "the quick brown fox")

      assert {:ok, _} = CommandRouter.write(name, uuid, "the slow brown fox")

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      assert Commonplace.Document.ContentType.get_content(doc) == "the slow brown fox"
    end

    test "write on a missing doc returns {:error, :not_found}", ctx do
      {_pid, name} = start_router(ctx)

      assert {:error, :not_found} =
               CommandRouter.write(name, UUID.uuid4(), "new content")
    end

    test "write broadcasts command events with byte counts", ctx do
      {_pid, name} = start_router(ctx)
      Magenta.subscribe(@command_topic)
      uuid = create_leaf_doc(ctx, "hello")

      assert {:ok, _} = CommandRouter.write(name, uuid, "hello world")

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.initiated", payload: init}}, 500
      assert init["verb"] == "write"
      assert init["args"]["uuid"] == uuid
      assert init["args"]["new_bytes"] == byte_size("hello world")

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.completed", payload: done}}, 500
      assert done["result"]["old_bytes"] == 5
      assert done["result"]["new_bytes"] == 11
    end

    # CX-2sv regression: the MCP write path hit a bug where rehydrating a
    # text doc from CubDB and then applying a diff produced an encoded
    # commit whose content was lost on re-decode. Only triggered when the
    # doc has a ContentType envelope (the sync agent's normal pattern) and
    # the doc has been through at least one save→reload cycle before the
    # write. The earlier single-write test above doesn't hit this because
    # it never rehydrates before the write.
    test "write survives rehydrate→write→reread on a sync-agent-style doc", ctx do
      {_pid, name} = start_router(ctx)
      uuid = UUID.uuid4()

      # Simulate how the sync agent creates a text doc on initial disk-read:
      # fresh Yelixer.Doc, ContentType.create, insert full file contents,
      # encode as a single commit.
      d1 = Yelixer.Doc.new()
      d1 = Commonplace.Document.ContentType.create(d1, :text, "test.txt")
      d1 = Commonplace.Document.ContentType.insert_text(d1, 0, "second version content")
      update1 = Yelixer.Encoding.encode_update(d1)
      CommitStore.create_commit(ctx.store, uuid, update1, nil)

      # Sanity check: reconstruct_snapshot (the path write takes) can read
      # the full content back.
      {:ok, read1} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      assert Commonplace.Document.ContentType.get_content(read1) == "second version content"

      # Now the MCP write path: CommandRouter.write rehydrates via
      # reconstruct_snapshot, Diff.apply_diff onto the rehydrated doc,
      # encode_update, create_chained_commit. The new commit should
      # decode back to the new content.
      assert {:ok, info} = CommandRouter.write(name, uuid, "replaced text")
      assert info["old_bytes"] == 22
      assert info["new_bytes"] == 13

      {:ok, read2} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      assert Commonplace.Document.ContentType.get_content(read2) == "replaced text"

      # A SECOND write must see the correct old_bytes, not 0, confirming
      # the commit really does persist the updated content.
      assert {:ok, info2} = CommandRouter.write(name, uuid, "third version")
      assert info2["old_bytes"] == 13
      assert info2["new_bytes"] == 13

      {:ok, read3} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      assert Commonplace.Document.ContentType.get_content(read3) == "third version"
    end

    # CX-o3r7: write must thread `signing_context` from its opts all the
    # way to the underlying CommitStore so the resulting commit is signed
    # by the SESSION's bound key, not whatever's in the global SecretStore.
    # Today, opts loses signing_context at the CommandRouter ↔ CommitStoreClient
    # boundary (CommitStoreClient.create_chained_commit/4 doesn't accept opts),
    # so MCP-initiated writes silently inherit the human's signing identity.
    test "write threads signing_context from opts into the underlying signed commit (CX-o3r7)",
         ctx do
      {_pid, name} = start_router(ctx)
      uuid = create_leaf_doc(ctx, "v1 contents")

      {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()

      session_ctx = %Commonplace.Crypto.SigningContext{
        identity_uuid: "test-session-agent",
        private_key: priv,
        public_key: pub
      }

      assert {:ok, _info} =
               CommandRouter.write(name, uuid, "v2 contents", signing_context: session_ctx)

      {:ok, latest} = CommitStore.latest_commit(ctx.store, uuid)

      assert latest.signature != nil,
             "commit must carry a signature when signing_context is supplied"

      assert String.starts_with?(latest.signer_id, "test-session-agent@"),
             "signer_id must encode the SigningContext's identity_uuid, " <>
               "got: #{inspect(latest.signer_id)}"

      assert :ok = Commonplace.Crypto.Signing.verify_commit(latest, pub),
             "signature must verify against the SigningContext's public key"
    end

    # Companion to the CX-o3r7 plumbing test: `signing_context: :unsigned`
    # opts in must skip signing even when the global SecretStore has a key.
    # Mirrors the CommitStore-level :unsigned escape hatch used by MCP-MVP
    # commits that should not inherit the human's identity.
    test "write with signing_context: :unsigned skips signing (CX-o3r7)", ctx do
      {_pid, name} = start_router(ctx)
      uuid = create_leaf_doc(ctx, "before")

      assert {:ok, _info} =
               CommandRouter.write(name, uuid, "after", signing_context: :unsigned)

      {:ok, latest} = CommitStore.latest_commit(ctx.store, uuid)
      assert latest.signature == nil
      assert latest.signer_id == nil
    end

    test "refuses to clobber a non-text doc unless force: true (CX-yfva)", ctx do
      {_pid, name} = start_router(ctx)
      uuid = UUID.uuid4()

      # Seed a :map-typed doc — anything non-:text triggers the guard.
      doc = Yelixer.Doc.new()
      doc = Commonplace.Document.ContentType.create(doc, :map, "config.json")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(ctx.store, uuid, update, nil)

      # Default — refused.
      assert {:error, {:type_mismatch, :map}} =
               CommandRouter.write(name, uuid, "plain text content")

      # Verify the doc was NOT mutated.
      {:ok, read} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      assert Commonplace.Document.ContentType.get_type(read) == :map

      # Force flag — proceeds.
      assert {:ok, info} =
               CommandRouter.write(name, uuid, "plain text content", force: true)

      assert info["forced"] == true
      assert info["new_bytes"] == byte_size("plain text content")
    end
  end

  describe "writer identity — persistent node-writer hand (CX-41qg.1)" do
    # Every write through CommandRouter used to reconstruct the doc via
    # `Yelixer.Doc.new()` — a fresh random client_id each call — then
    # splice and re-encode under that random id. A CRDT's state vector
    # grows one entry per DISTINCT client that has ever authored an op,
    # so N writes from CommandRouter used to mint N client ids and bloat
    # the SV without bound. The fix gives the write funnel a stable
    # per-doc client_id (`:erlang.phash2(uuid, 0xFFFF_FFFF)`, the same
    # scheme Sync.Agent already uses — CX-pyi) so repeated writes to the
    # same doc converge on (at most) a couple of client slots.
    defp sv_client_ids(doc) do
      Yelixer.BlockStore.state_vector(doc.store).clocks
      |> Map.keys()
      |> MapSet.new()
    end

    test "20 sequential writes to the same doc keep the state vector's client-id set bounded",
         ctx do
      {_pid, name} = start_router(ctx)
      uuid = create_leaf_doc(ctx, "seed")

      Enum.each(1..20, fn n ->
        assert {:ok, _} = CommandRouter.write(name, uuid, "content version #{n}")
      end)

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      client_ids = sv_client_ids(doc)

      assert MapSet.size(client_ids) <= 2,
             "expected a bounded (<=2) set of client ids after 20 writes, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)} " <>
               "(pre-fix behavior would show one new client id per write, i.e. ~20)"
    end

    test "20 sequential writes still compose correctly under the stable client id", ctx do
      {_pid, name} = start_router(ctx)
      uuid = create_leaf_doc(ctx, "seed")

      final =
        Enum.reduce(1..20, "seed", fn n, _prev ->
          new_content = "content version #{n}"
          assert {:ok, _} = CommandRouter.write(name, uuid, new_content)
          new_content
        end)

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      assert Commonplace.Document.ContentType.get_content(doc) == final
    end

    test "the forced-clobber write path also uses the stable client id", ctx do
      {_pid, name} = start_router(ctx)
      uuid = UUID.uuid4()

      doc = Yelixer.Doc.new()
      doc = Commonplace.Document.ContentType.create(doc, :map, "config.json")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(ctx.store, uuid, update, nil)

      Enum.each(1..10, fn n ->
        assert {:ok, _} =
                 CommandRouter.write(name, uuid, "forced content #{n}", force: true)
      end)

      {:ok, read} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      client_ids = sv_client_ids(read)

      assert MapSet.size(client_ids) <= 2,
             "forced-clobber writes must also mint under the stable client id, " <>
               "got #{MapSet.size(client_ids)} client ids: #{inspect(client_ids)}"
    end

    test "branch_set_sync (schema) writes also use the stable client id", ctx do
      {_pid, name} = start_router(ctx)

      child_uuid = UUID.uuid4()
      child_doc = Schema.new_schema()
      child_update = Yelixer.Encoding.encode_update(child_doc)
      CommitStore.create_commit(ctx.store, child_uuid, child_update, nil)

      parent_doc = Schema.new_schema()
      parent_doc = Schema.add_directory(parent_doc, "feature-x", child_uuid)
      parent_update = Yelixer.Encoding.encode_update(parent_doc)
      CommitStore.create_chained_commit(ctx.store, ctx.root, parent_update)

      Enum.each(1..10, fn _ ->
        assert {:ok, _} = CommandRouter.branch_deactivate(name, ctx.root, "feature-x")
        assert {:ok, _} = CommandRouter.branch_activate(name, ctx.root, "feature-x")
      end)

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      client_ids = sv_client_ids(doc)

      assert MapSet.size(client_ids) <= 2,
             "schema (branch_set_sync) writes must also mint under a stable client id, " <>
               "got #{MapSet.size(client_ids)} client ids: #{inspect(client_ids)}"
    end

    test "a doc written by CommandRouter and by a second stable-id writer (simulating " <>
           "Sync.Agent's shared phash2(uuid) scheme) converges without clock collision or " <>
           "lost writes",
         ctx do
      {_pid, name} = start_router(ctx)
      uuid = create_leaf_doc(ctx, "seed")

      stable_id = :erlang.phash2(uuid, 0xFFFF_FFFF)

      # Writer A: CommandRouter's write funnel.
      assert {:ok, _} = CommandRouter.write(name, uuid, "seed plus A1")

      # Writer B: a second writer using the identical stable-per-doc-uuid
      # client id scheme (this is exactly what Sync.Agent's
      # stable_client_id/1 does) but going straight through
      # CommitStoreClient, bypassing CommandRouter entirely — simulating
      # the sync agent touching the same doc.
      {:ok, doc_b} =
        Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid, client_id: stable_id)

      old_content = Commonplace.Document.ContentType.get_content(doc_b) || ""

      doc_b =
        Commonplace.Document.Diff.apply_diff(doc_b, old_content, "seed plus A1 plus B1")

      update_b = Yelixer.Encoding.encode_update(doc_b)
      Commonplace.Store.CommitStoreClient.create_chained_commit(ctx.store, uuid, update_b)

      # Writer A again.
      assert {:ok, _} = CommandRouter.write(name, uuid, "seed plus A1 plus B1 plus A2")

      {:ok, final_doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, uuid)
      assert Commonplace.Document.ContentType.get_content(final_doc) ==
               "seed plus A1 plus B1 plus A2"

      client_ids = sv_client_ids(final_doc)

      assert MapSet.size(client_ids) <= 2,
             "shared stable-id writers must converge on the same (bounded) client slots, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)}"
    end
  end

  describe "branch_activate / branch_deactivate" do
    defp setup_parent_with_child_dir(ctx) do
      # Create a child dir and attach it to the root schema.
      child_uuid = UUID.uuid4()
      child_doc = Schema.new_schema()
      child_update = Yelixer.Encoding.encode_update(child_doc)
      CommitStore.create_commit(ctx.store, child_uuid, child_update, nil)

      parent_doc = Schema.new_schema()
      parent_doc = Schema.add_directory(parent_doc, "feature-x", child_uuid)
      parent_update = Yelixer.Encoding.encode_update(parent_doc)
      CommitStore.create_chained_commit(ctx.store, ctx.root, parent_update)
      child_uuid
    end

    test "branch_deactivate sets sync=false on the named entry", ctx do
      {_pid, name} = start_router(ctx)
      _child_uuid = setup_parent_with_child_dir(ctx)

      assert {:ok, _} = CommandRouter.branch_deactivate(name, ctx.root, "feature-x")

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, entry} = Schema.get_entry(doc, "feature-x")
      refute entry.sync
    end

    test "branch_activate sets sync=true on the named entry", ctx do
      {_pid, name} = start_router(ctx)
      _child_uuid = setup_parent_with_child_dir(ctx)

      # First deactivate, then activate
      assert {:ok, _} = CommandRouter.branch_deactivate(name, ctx.root, "feature-x")
      assert {:ok, _} = CommandRouter.branch_activate(name, ctx.root, "feature-x")

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, entry} = Schema.get_entry(doc, "feature-x")
      assert entry.sync
    end

    test "branch_activate on a missing entry returns {:error, :not_found}", ctx do
      {_pid, name} = start_router(ctx)

      assert {:error, :not_found} =
               CommandRouter.branch_activate(name, ctx.root, "nope")
    end

    # CX-hoj: branch_activate/branch_deactivate create a real chained
    # commit (the schema mutation) but, until this bead, silently
    # dropped `signing_context` on the floor — every branch toggle
    # inherited whatever the global SecretStore fallback signs with,
    # never the session's bound key. Mirrors the CX-o3r7 write test.
    test "branch_deactivate threads signing_context from opts into the schema commit (CX-hoj)",
         ctx do
      {_pid, name} = start_router(ctx)
      _child_uuid = setup_parent_with_child_dir(ctx)

      {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()

      session_ctx = %Commonplace.Crypto.SigningContext{
        identity_uuid: "test-session-agent",
        private_key: priv,
        public_key: pub
      }

      assert {:ok, _} =
               CommandRouter.branch_deactivate(name, ctx.root, "feature-x",
                 signing_context: session_ctx
               )

      {:ok, latest} = CommitStore.latest_commit(ctx.store, ctx.root)

      assert latest.signature != nil,
             "schema commit must carry a signature when signing_context is supplied"

      assert String.starts_with?(latest.signer_id, "test-session-agent@"),
             "signer_id must encode the SigningContext's identity_uuid, " <>
               "got: #{inspect(latest.signer_id)}"
    end

    test "branch activate broadcasts command.initiated and command.completed", ctx do
      {_pid, name} = start_router(ctx)
      _child_uuid = setup_parent_with_child_dir(ctx)
      Magenta.subscribe(@command_topic)

      assert {:ok, _} = CommandRouter.branch_activate(name, ctx.root, "feature-x")

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.initiated", payload: init}}, 500
      assert init["verb"] == "branch_activate"
      assert init["args"]["parent_uuid"] == ctx.root
      assert init["args"]["name"] == "feature-x"

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.completed"}}, 500
    end
  end

  describe "gc" do
    test "returns reachable and orphaned counts", ctx do
      {_pid, name} = start_router(ctx)

      assert {:ok, report} = CommandRouter.gc(name, ctx.root)
      assert is_map(report)
      assert is_integer(report["reachable_count"])
      assert is_integer(report["orphaned_count"])
      assert is_list(report["orphaned_uuids"])
    end

    test "broadcasts command.completed with the gc result", ctx do
      {_pid, name} = start_router(ctx)
      Magenta.subscribe(@command_topic)

      assert {:ok, _} = CommandRouter.gc(name, ctx.root)

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.initiated", payload: init}}, 500
      assert init["verb"] == "gc"
      assert init["args"]["root_uuid"] == ctx.root

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.completed"}}, 500
    end
  end
end
