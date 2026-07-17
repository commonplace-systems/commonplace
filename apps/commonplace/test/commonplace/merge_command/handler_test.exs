defmodule Commonplace.MergeCommand.HandlerTest do
  @moduledoc """
  CX-8qzi: magenta merge command handler.

  Singleton GenServer that subscribes to magenta commands with verb
  "merge" (via `Magenta.subscribe_to_verb/1` — sentinel dispatch so
  Phoenix.PubSub's lack of wildcard subscribe doesn't force a per-path
  subscriber tree). When a command arrives:

  - Topic: `magenta:commands/{path}/merge`
  - Incoming type: `"merge"` (request)
  - Payload: `%{"other_ref" => <lowercase-hex>, "strategy" => "translate"|"merge_snapshot"}`
  - Dispatches to `MergePolicy.merge/4` after canonicalizing
    `(latest, other_ref)` by CID (CX-1mml)
  - Publishes literal `"merge_completed"` or `"merge_failed"` magenta
    messages back on the same per-path topic so subscribers (callers,
    red-log onramps) see the outcome anchored at the path that was
    addressed.

  Per plan-bot msg 2307 (jes answer) + 2313/2315:
  - A = dynamic per-path topics (preserved at the topic address level)
  - B = literal magenta types (NOT generic Events.run envelope)
  - C = per-document red log at {path} (handled by onramp wiring, a
    follow-up layer on this handler)
  - Topology β: singleton handler + Magenta verb sentinel, no per-path
    supervision tree (no per-path state worth isolating)
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.{Magenta, RedLog}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "mcmd_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"mcmd_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Every handler test has a workspace root schema so CX-3hvu path
    # resolution can walk "commands/{path}/merge" → doc UUID.
    root_uuid = "mcmd-root-#{:rand.uniform(1_000_000)}"
    root_schema = Schema.new_schema()
    root_update = Encoding.encode_update(root_schema)
    CommitStore.create_commit(name, root_uuid, root_update, nil)

    handler_name = :"mcmd_handler_#{:rand.uniform(1_000_000)}"

    start_supervised!(
      {Commonplace.MergeCommand.Handler,
       store: name, name: handler_name, root_uuid: root_uuid}
    )

    %{store: name, handler: handler_name, root: root_uuid}
  end

  # Like build_l_r but the merge target is a schema doc — L adds an
  # "l_entry" file, R adds an "r_entry" file as a sibling. CX-3hvu
  # requires a schema-typed target so __merge.log can attach.
  defp build_schema_l_r(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = build_schema_doc(1)

    _reg =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_c),
        %{kind: :regular}
      )

    {:ok, c_snap} = CommitStore.snapshot(store, uuid)

    doc_l = build_schema_doc(2)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_snap.update)
    doc_l = Schema.add_file(doc_l, "l_entry", "uuid-l-entry-placeholder")

    l_commit =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_l),
        %{kind: :regular}
      )

    doc_r = build_schema_doc(3)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_snap.update)
    doc_r = Schema.add_file(doc_r, "r_entry", "uuid-r-entry-placeholder")

    r_commit =
      Commit.new(uuid, Encoding.encode_update(doc_r), c_snap.id, %{
        kind: :regular,
        snapshot_parent: c_snap.id
      })

    :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

    {l_commit, r_commit}
  end

  defp build_schema_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "__schema", :map)
    {doc, _} = Doc.get_or_create_type(doc, "entries", :map)
    Yelixer.Types.YMap.set(doc, "__schema", "version", "1")
  end

  defp load_schema(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  # Register `name` in the workspace root schema as a file entry pointing
  # at `uuid`. Used so the handler can resolve {path} → doc UUID via
  # Tree.Walk. Returns the path to use in the magenta topic.
  defp register_in_root(store, root_uuid, name, uuid) do
    {:ok, root_commit} = CommitStore.latest_commit(store, root_uuid)
    schema = Schema.new_schema()
    {:ok, schema} = Encoding.apply_update(schema, root_commit.update)
    schema = Schema.add_file(schema, name, uuid)

    CommitStore.create_chained_commit(
      store,
      root_uuid,
      Encoding.encode_update(schema)
    )

    name
  end

  # Reuse MergePolicyTest fixture shape: snapshot C → L chained regular
  # → R sibling regular. L.namespace = {1,2}, R.namespace = {1,3}.
  defp build_l_r(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    _reg =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_c),
        %{kind: :regular}
      )

    {:ok, c_snap} = CommitStore.snapshot(store, uuid)

    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snap.update)
    c_update = Encoding.encode_update(c_doc)

    doc_l = Doc.new(client_id: 2)
    {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_update)
    doc_l = Text.insert(doc_l, "t", 0, "X")

    l_commit =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_l),
        %{kind: :regular}
      )

    doc_r = Doc.new(client_id: 3)
    {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
    doc_r = Text.insert(doc_r, "t", 3, "Y")

    r_commit =
      Commit.new(uuid, Encoding.encode_update(doc_r), c_snap.id, %{
        kind: :regular,
        snapshot_parent: c_snap.id
      })

    :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

    {l_commit, r_commit}
  end

  describe "merge command → merge_completed" do
    test "publishes merge_completed on the same path topic after successful merge",
         %{store: store, root: root} do
      uuid = "mcmd-happy"
      {_l, r} = build_l_r(store, uuid)

      path = register_in_root(store, root, "happy_doc", uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"} = reply}, 2000
      assert is_binary(reply.payload["commit_id"])
      assert reply.payload["path"] == path
    end

    test "merge_completed payload contains the new commit id that is findable in the store",
         %{store: store, root: root} do
      uuid = "mcmd-commit-id"
      {_l, r} = build_l_r(store, uuid)

      path = register_in_root(store, root, "commit_id_doc", uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"} = reply}, 2000

      commit_id = Base.decode16!(reply.payload["commit_id"], case: :lower)
      assert {:ok, stored} = CommitStore.get_commit(store, commit_id)
      assert stored.metadata[:kind] == :merge
    end
  end

  describe "merge command → merge_failed" do
    test "publishes merge_failed when path doesn't resolve to a registered doc",
         %{store: _store} do
      path = "bad/path"
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => String.duplicate("f", 64),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_failed"} = reply}, 2000
      assert reply.payload["path"] == path
      assert reply.payload["reason"] =~ "path_unresolved"
    end
  end

  describe "path-resolved l_id (CX-3hvu)" do
    test "merge command with no l_id in payload resolves l from path's HEAD",
         %{store: store, root: root} do
      uuid = "mcmd-pathres"
      {_l, r} = build_l_r(store, uuid)

      path = register_in_root(store, root, "pathres_doc", uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"} = reply}, 2000
      assert is_binary(reply.payload["commit_id"])
      assert reply.payload["path"] == path

      commit_id = Base.decode16!(reply.payload["commit_id"], case: :lower)
      {:ok, stored} = CommitStore.get_commit(store, commit_id)
      assert stored.metadata[:kind] == :merge
    end
  end

  describe "cross-peer determinism (CX-1mml)" do
    test "two handlers with swapped {latest, other_ref} produce byte-identical merge commits",
         %{store: store_a, root: root_a} do
      # Peer A: chained L is :latest, sibling R imported.
      uuid = "mcmd-determ-a"
      {l, r} = build_l_r(store_a, uuid)

      # Use distinct entry names per peer. Both handlers subscribe to
      # the "merge" verb sentinel (β topology), so both receive every
      # message — we keep each peer's handler isolated from the other's
      # request by making the path resolve only in the matching peer's
      # root. Before CX-nuc2, the incidental __merge.log write moved
      # peer A's :latest to a schema-shaped commit, so peer A's handler
      # error-pathed on the second request and never emitted
      # merge_completed; that accidentally isolated the test. Leaf-doc
      # merges now leave the target untouched, so we isolate explicitly.
      path_a = register_in_root(store_a, root_a, "determ_a_doc", uuid)
      topic_a = "commands/#{path_a}/merge"

      Magenta.subscribe(topic_a)

      # First request runs through this test's handler (the one started
      # in setup) — its :latest = L, so it merges (L, R).
      Magenta.send(
        topic_a,
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })
      )

      assert_receive {:magenta, ^topic_a, %Magenta{type: "merge_completed"} = reply_a}, 2000
      commit_a_id = Base.decode16!(reply_a.payload["commit_id"], case: :lower)

      # Now stand up an independent peer-B store/handler whose :latest
      # for the same uuid is R (the swap of A's local view). The merge
      # command on B uses other_ref = L. With CX-1mml canonicalization,
      # the resulting commit must match A's byte-for-byte.
      dir_b = Path.join(System.tmp_dir!(), "mcmd_peer_b_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir_b)
      store_b = :"mcmd_b_store_#{:rand.uniform(1_000_000)}"
      {:ok, pid_b} = CommitStore.start_link(data_dir: dir_b, name: store_b)
      on_exit(fn ->
        if Process.alive?(pid_b), do: (try do GenServer.stop(pid_b) catch (:exit, _ -> :ok) end)
        File.rm_rf!(dir_b)
      end)

      seed_peer_b_with_r_as_latest(store_b, uuid, l, r)

      root_b = "mcmd-root-b-#{:rand.uniform(1_000_000)}"
      root_schema_b = Schema.new_schema()
      CommitStore.create_commit(store_b, root_b, Encoding.encode_update(root_schema_b), nil)
      register_in_root(store_b, root_b, "determ_b_doc", uuid)

      handler_b = :"mcmd_handler_b_#{:rand.uniform(1_000_000)}"

      {:ok, handler_b_pid} =
        Commonplace.MergeCommand.Handler.start_link(
          store: store_b,
          name: handler_b,
          root_uuid: root_b
        )

      on_exit(fn ->
        if Process.alive?(handler_b_pid), do: (try do GenServer.stop(handler_b_pid) catch (:exit, _ -> :ok) end)
      end)

      topic_b = "commands/determ_b_doc/merge"
      Magenta.subscribe(topic_b)

      Magenta.send(
        topic_b,
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(l.id, case: :lower),
          "strategy" => "translate"
        })
      )

      assert_receive {:magenta, ^topic_b, %Magenta{type: "merge_completed"} = reply_b}, 2000
      commit_b_id = Base.decode16!(reply_b.payload["commit_id"], case: :lower)

      # Byte-identical commit ids = byte-identical commit content (the
      # id IS the content hash). Persistence on peer B is a separate
      # concern: write_prebuilt_commit_cas requires commit.parent_id ==
      # :latest. When canonicalization picks the OTHER peer's :latest as
      # the parent, the local CAS write returns :parent_moved (a no-op
      # by current handler convention). That's the autonomous-convergence
      # gap tracked in CX-8k1v — orthogonal to CX-1mml's determinism
      # invariant.
      assert commit_a_id == commit_b_id,
             "expected byte-identical commit ids across peers (A=#{Base.encode16(commit_a_id, case: :lower)}, B=#{Base.encode16(commit_b_id, case: :lower)})"
    end
  end

  # Build the same {L, R} sibling shape on a fresh peer-B store, but
  # arrange so that R is on :latest (B's local-chain side) and L is
  # the imported sibling. This is the swap of `build_l_r`'s shape.
  defp seed_peer_b_with_r_as_latest(store, uuid, l, r) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    # Replicate the C-snapshot stage so both peers share the same
    # snapshot_parent for the sibling commits.
    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    _reg =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_c),
        %{kind: :regular}
      )

    {:ok, _c_snap} = CommitStore.snapshot(store, uuid)

    # Import R directly as a chained regular commit so it becomes :latest.
    :ok = CommitStore.import_commit(store, r, validator: fn _ -> :ok end)
    :ok = CommitStore.set_latest(store, uuid, r.id)

    # Import L as the off-chain sibling.
    :ok = CommitStore.import_commit(store, l, validator: fn _ -> :ok end)

    :ok
  end

  describe "merge log onramp (CX-3hvu)" do
    test "merge_completed event is persisted in __merge.log under the target schema",
         %{store: store, root: root, handler: handler} do
      target_uuid = "mcmd-mergelog-target"
      {_l, r} = build_schema_l_r(store, target_uuid)

      path = register_in_root(store, root, "mergelog_doc", target_uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"}}, 2000

      # Flush the onramp so its in-memory log state is committed to the
      # store before we read it.
      {:ok, onramp} = GenServer.call(handler, {:get_onramp, path})
      RedLog.commit_onramp(onramp)

      # __merge.log should now be a schema entry under the target doc.
      target_schema = load_schema(store, target_uuid)
      assert {:ok, log_entry} = Schema.get_entry(target_schema, "__merge.log")
      assert log_entry.type == :doc

      log = RedLog.load(log_entry.node_id, store)
      events = RedLog.read(log)

      assert Enum.any?(events, fn e ->
               e["type"] == "merge_completed" and e["payload"]["path"] == path
             end),
             "expected merge_completed event in __merge.log, got: #{inspect(events)}"
    end

    test "second merge on same path reuses the onramp (no duplicate process)",
         %{store: store, root: root, handler: handler} do
      target_uuid = "mcmd-reuse-target"
      {_l, r} = build_schema_l_r(store, target_uuid)

      path = register_in_root(store, root, "reuse_doc", target_uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)
      assert_receive {:magenta, ^topic, %Magenta{}}, 2000
      {:ok, onramp_first} = GenServer.call(handler, {:get_onramp, path})

      Magenta.send(topic, request)
      assert_receive {:magenta, ^topic, %Magenta{}}, 2000
      {:ok, onramp_second} = GenServer.call(handler, {:get_onramp, path})

      assert onramp_first == onramp_second
      assert Process.alive?(onramp_first)
    end
  end

  describe "leaf-doc merge log (CX-nuc2)" do
    test "merge on a leaf-doc target does NOT add a __merge.log entry to the target",
         %{store: store, root: root} do
      target_uuid = "mcmd-leaf-no-entry"
      {_l, r} = build_l_r(store, target_uuid)

      path = register_in_root(store, root, "leaf_no_entry_doc", target_uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)
      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"}}, 2000

      # The target is a text doc. Adding a "__merge.log" schema entry
      # into it would write a schema-shaped commit over a text chain,
      # corrupting the leaf. The CX-nuc2 design puts the merge log at a
      # separate UUID5-derived UUID, so the leaf target's own schema view
      # must stay empty.
      target_schema = load_schema(store, target_uuid)
      assert :error = Schema.get_entry(target_schema, "__merge.log")
    end

    test "merge_completed event is persisted in the UUID5-derived per-doc merge log",
         %{store: store, root: root, handler: handler} do
      target_uuid = "mcmd-leaf-mergelog"
      {_l, r} = build_l_r(store, target_uuid)

      path = register_in_root(store, root, "leaf_mergelog_doc", target_uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)
      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"}}, 2000

      # Flush the onramp to persist events before reading.
      {:ok, onramp} = GenServer.call(handler, {:get_onramp, path})
      RedLog.commit_onramp(onramp)

      # The log lives at the deterministic UUID5-derived address — no
      # schema entry points at it, but any peer can rediscover it given
      # the target_uuid.
      log_uuid = Commonplace.MergeCommand.MergeLog.log_uuid_for_doc(target_uuid)
      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      assert Enum.any?(events, fn e ->
               e["type"] == "merge_completed" and e["payload"]["path"] == path
             end),
             "expected merge_completed event in leaf-doc merge log, got: #{inspect(events)}"
    end

    test "second merge on the same leaf doc reuses the in-memory onramp",
         %{store: store, root: root, handler: handler} do
      target_uuid = "mcmd-leaf-reuse"
      {_l, r} = build_l_r(store, target_uuid)

      path = register_in_root(store, root, "leaf_reuse_doc", target_uuid)
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)
      assert_receive {:magenta, ^topic, %Magenta{}}, 2000
      {:ok, onramp_first} = GenServer.call(handler, {:get_onramp, path})

      Magenta.send(topic, request)
      assert_receive {:magenta, ^topic, %Magenta{}}, 2000
      {:ok, onramp_second} = GenServer.call(handler, {:get_onramp, path})

      assert onramp_first == onramp_second
      assert Process.alive?(onramp_first)
    end
  end

  describe "sentinel verb dispatch (β topology)" do
    test "handler receives commands on multiple per-path topics ending in /merge",
         %{store: store, root: root} do
      uuid_a = "mcmd-multi-a"
      uuid_b = "mcmd-multi-b"
      {_l_a, r_a} = build_l_r(store, uuid_a)
      {_l_b, r_b} = build_l_r(store, uuid_b)

      path_a = register_in_root(store, root, "multi_a_doc", uuid_a)
      path_b = register_in_root(store, root, "multi_b_doc", uuid_b)
      topic_a = "commands/#{path_a}/merge"
      topic_b = "commands/#{path_b}/merge"

      Magenta.subscribe(topic_a)
      Magenta.subscribe(topic_b)

      req_a =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r_a.id, case: :lower),
          "strategy" => "translate"
        })

      req_b =
        Magenta.message("merge", "test", %{
          "other_ref" => Base.encode16(r_b.id, case: :lower),
          "strategy" => "translate"
        })

      Magenta.send(topic_a, req_a)
      Magenta.send(topic_b, req_b)

      assert_receive {:magenta, ^topic_a, %Magenta{type: "merge_completed"}}, 2000
      assert_receive {:magenta, ^topic_b, %Magenta{type: "merge_completed"}}, 2000
    end

    test "handler ignores magenta messages of other types", %{store: _store} do
      path = "noise"
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      unrelated =
        Magenta.message("some_other_verb", "test", %{"key" => "value"})

      Magenta.send(topic, unrelated)

      refute_receive {:magenta, _, %Magenta{type: "merge_completed"}}, 200
      refute_receive {:magenta, _, %Magenta{type: "merge_failed"}}, 200
    end
  end
end
