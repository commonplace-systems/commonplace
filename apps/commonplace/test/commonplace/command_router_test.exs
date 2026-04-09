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
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
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
