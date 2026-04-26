defmodule Commonplace.ViewComputeTest do
  use ExUnit.Case, async: false

  alias Commonplace.ViewCompute
  alias Commonplace.CommandRouter
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType
  alias Commonplace.Tree.DocBuilder

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_vc_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    store_name = :"commit_store_vc_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    # Dedicated CommandRouter bound to this test's store so writes
    # don't collide with the app's global router (which uses the
    # default CommitStoreClient).
    router_name = :"router_vc_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommandRouter, name: router_name, store: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name, router: router_name, dir: dir}
  end

  defp seed_text_doc(store, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "seed")
    # Yelixer.Types.Text.insert rejects empty binaries, so only insert
    # when content is non-empty. An empty-content doc is a valid seeded
    # state — the first compute will grow it via Diff.apply_diff.
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp read_content(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  describe "ViewCompute" do
    test "runs initial compute at startup and writes to target", %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "hello world")
      target_uuid = seed_text_doc(store, "")

      compute_fn = fn src -> "VIEW: " <> String.upcase(src) end

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          compute_fn: compute_fn,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target_uuid) == "VIEW: HELLO WORLD" end)
      GenServer.stop(pid)
    end

    test "recomputes when source doc receives a new commit", %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "original")
      target_uuid = seed_text_doc(store, "")

      compute_fn = fn src -> "[[" <> src <> "]]" end

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          compute_fn: compute_fn,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target_uuid) == "[[original]]" end)

      # Write a new version of the source via the dedicated router
      {:ok, _} = CommandRouter.write(router, source_uuid, "updated")

      # CommitStore broadcasts on blue:UUID → ViewCompute picks it up →
      # recomputes and writes to target
      :ok = wait_until(fn -> read_content(store, target_uuid) == "[[updated]]" end)

      GenServer.stop(pid)
    end

    test "recompute/1 forces a synchronous recompute", %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "start")
      target_uuid = seed_text_doc(store, "")

      compute_fn = fn src -> String.upcase(src) end

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          compute_fn: compute_fn,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target_uuid) == "START" end)

      # Mutate source without going through the router (so no broadcast)
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "seed")
      doc = ContentType.insert_text(doc, 0, "second")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(store, source_uuid, update)

      # force a sync recompute
      :ok = ViewCompute.recompute(pid)
      assert read_content(store, target_uuid) == "SECOND"

      GenServer.stop(pid)
    end
  end

  # CX-wxbp (M5 sub-bead iii): :spec_uuid opt path. ViewCompute reads
  # a Commonplace.View.ComputeSpec doc at init, builds compute_fn from
  # the parsed spec, and restart-on-spec-commit (terminates self;
  # supervisor re-starts which re-reads + re-parses).
  describe "ViewCompute :spec_uuid opt (M5 sub-bead iii)" do
    @chat_compute_spec """
    <compute-spec schema="1">
      <pipeline>
        <step kind="decode_json_array"/>
        <step kind="materialize">
          <chains>
            <chain field="edit_of" semantics="latest_replaces"/>
            <chain field="tombstone_of" semantics="marks_deleted"/>
          </chains>
        </step>
        <step kind="render">
          <function module="Commonplace.Chat.ChatViewBuilder" name="build_view_xml"/>
        </step>
      </pipeline>
    </compute-spec>
    """

    defp seed_messages_doc(store) do
      uuid = UUID.uuid4()
      doc = Commonplace.Chat.Messages.new()
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)
      uuid
    end

    defp seed_view_doc(store) do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "_view.xml")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)
      uuid
    end

    defp seed_compute_spec(store, xml) do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "_compute")
      doc = ContentType.insert_text(doc, 0, xml)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)
      uuid
    end

    test "init reads spec doc + computes view-XML from it",
         %{store: store, router: router} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)
      spec_uuid = seed_compute_spec(store, @chat_compute_spec)

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          spec_uuid: spec_uuid,
          spec_context: %{room_name: "general"},
          store: store,
          router: router
        )

      :ok =
        wait_until(fn ->
          content = read_content(store, target_uuid) || ""
          content =~ "general" and content =~ "<view"
        end)

      GenServer.stop(pid)
    end

    test "init/1 errors when both :compute_fn and :spec_uuid are supplied",
         %{store: store, router: router} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)
      spec_uuid = seed_compute_spec(store, @chat_compute_spec)

      Process.flag(:trap_exit, true)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ViewCompute.start_link(
            source_uuid: source_uuid,
            target_uuid: target_uuid,
            spec_uuid: spec_uuid,
            compute_fn: fn x -> x end,
            store: store,
            router: router
          )
        end)

      assert {:error, _} = result
    end

    test "init/1 errors when neither :compute_fn nor :spec_uuid is supplied",
         %{store: store, router: router} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)

      Process.flag(:trap_exit, true)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ViewCompute.start_link(
            source_uuid: source_uuid,
            target_uuid: target_uuid,
            store: store,
            router: router
          )
        end)

      assert {:error, _} = result
    end

    test "init/1 errors when spec doc is malformed",
         %{store: store, router: router} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)
      bad_spec_uuid = seed_compute_spec(store, "<not-compute-spec/>")

      Process.flag(:trap_exit, true)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ViewCompute.start_link(
            source_uuid: source_uuid,
            target_uuid: target_uuid,
            spec_uuid: bad_spec_uuid,
            store: store,
            router: router
          )
        end)

      assert {:error, _} = result
    end

    test "spec doc commit triggers instance termination (supervisor would restart)",
         %{store: store, router: router} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)
      spec_uuid = seed_compute_spec(store, @chat_compute_spec)

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          spec_uuid: spec_uuid,
          spec_context: %{room_name: "general"},
          store: store,
          router: router
        )

      Process.monitor(pid)

      # Simulate the spec doc receiving a new commit (e.g. operator
      # edits the chat compute spec). ViewCompute should terminate so
      # supervisor restarts it (which re-reads the new spec).
      send(pid, {:commit, spec_uuid, "fake-commit-id", %{}})

      assert_receive {:DOWN, _ref, :process, ^pid, _reason}, 500
    end
  end

  defp wait_until(fun, deadline_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(50)
        do_wait(fun, deadline)
      end
    end
  end
end
