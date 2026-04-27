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

  # CX-6fhe (M6 sub-bead iii): code_uuid as third commit subscription.
  # When spec uses M6 <function ref> form, ViewCompute resolves the
  # source-doc UUID at init, subscribes to its commits, and restarts
  # on any source-edit (eventually consistent with spec edits).
  describe "ViewCompute code_uuid subscription (M6 sub-bead iii)" do
    alias Commonplace.Code.SourceDoc
    alias Commonplace.Tree.Schema

    setup %{store: store} do
      SourceDoc.reset_cache()

      # Seed a synthetic tree so the M6 spec can resolve "../_renderer.ex"
      # M5 callers don't hit this path; only M6 specs need it.
      renderer_source = """
      defmodule Cp.Test.M6Live do
        def render(entries, room) do
          items = Enum.map_join(entries, ",", & &1["title"] || "_")
          "<live room=\\"\#{room}\\">\#{items}</live>"
        end
      end
      """

      renderer_uuid = UUID.uuid4()
      renderer_doc = Yelixer.Doc.new()
      renderer_doc = ContentType.create(renderer_doc, :text, "_renderer.ex")
      renderer_doc = ContentType.insert_text(renderer_doc, 0, renderer_source)
      update = Yelixer.Encoding.encode_update(renderer_doc)
      CommitStore.create_commit(store, renderer_uuid, update, nil)

      spec_xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="decode_json_array"/>
          <step kind="render">
            <function ref="../_renderer.ex" name="render"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      spec_uuid = UUID.uuid4()
      spec_doc = Yelixer.Doc.new()
      spec_doc = ContentType.create(spec_doc, :text, "_compute")
      spec_doc = ContentType.insert_text(spec_doc, 0, spec_xml)
      update = Yelixer.Encoding.encode_update(spec_doc)
      CommitStore.create_commit(store, spec_uuid, update, nil)

      dir_uuid = UUID.uuid4()
      dir_schema = Schema.new_schema()
      dir_schema = Schema.add_file(dir_schema, "_renderer.ex", renderer_uuid)
      dir_schema = Schema.add_file(dir_schema, "_compute", spec_uuid)
      update = Yelixer.Encoding.encode_update(dir_schema)
      CommitStore.create_commit(store, dir_uuid, update, nil)

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_directory(root_doc, "test", dir_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root_uuid, update, nil)
      File.write!(Path.join(Application.get_env(:commonplace, :data_dir, "tmp/test_data"), "root"), root_uuid)

      on_exit(fn -> SourceDoc.reset_cache() end)

      %{spec_uuid: spec_uuid, renderer_uuid: renderer_uuid, root_uuid: root_uuid}
    end

    test "code_uuid subscription is set up at init for M6 form",
         %{store: store, router: router, spec_uuid: spec_uuid, renderer_uuid: renderer_uuid, root_uuid: root_uuid} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          spec_uuid: spec_uuid,
          spec_context: %{room_name: "alpha", spec_path: "test/_compute", root_uuid: root_uuid},
          store: store,
          router: router
        )

      state = ViewCompute.state(pid)
      assert renderer_uuid in state.code_uuids

      GenServer.stop(pid)
    end

    test "commit on code_uuid triggers {:stop, :normal} (round-1: restart-the-instance)",
         %{store: store, router: router, spec_uuid: spec_uuid, renderer_uuid: renderer_uuid, root_uuid: root_uuid} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          spec_uuid: spec_uuid,
          spec_context: %{room_name: "alpha", spec_path: "test/_compute", root_uuid: root_uuid},
          store: store,
          router: router
        )

      Process.monitor(pid)

      send(pid, {:commit, renderer_uuid, "fake-commit-id", %{}})

      assert_receive {:DOWN, _ref, :process, ^pid, _reason}, 500
    end

    test "M5 specs (no <function ref>) have empty code_uuids list",
         %{store: store, router: router} do
      source_uuid = seed_messages_doc(store)
      target_uuid = seed_view_doc(store)
      m5_spec_uuid = seed_compute_spec(store, @chat_compute_spec)

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          spec_uuid: m5_spec_uuid,
          spec_context: %{room_name: "general"},
          store: store,
          router: router
        )

      state = ViewCompute.state(pid)
      assert state.code_uuids == []

      GenServer.stop(pid)
    end
  end

  # CX-fe7f (M7 sub-bead iii): :code_uuid opt replaces :spec_uuid for
  # the M7 Elixir-source-as-pipeline path. Mutex with :compute_fn and
  # :spec_uuid (legacy; kept until sub-bead v deletes ComputeSpec).
  describe "ViewCompute :code_uuid opt (M7 sub-bead iii)" do
    alias Commonplace.Code.SourceDoc

    setup do
      SourceDoc.reset_cache()
      on_exit(fn -> SourceDoc.reset_cache() end)
      :ok
    end

    defp seed_compute_doc(store, source_string) do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "_compute")
      doc = ContentType.insert_text(doc, 0, source_string)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)
      uuid
    end

    test "init reads compute-doc + computes via ComputeRunner",
         %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "hello")
      target_uuid = seed_text_doc(store, "")

      compute_source = ~S"""
      defmodule Cp.Test.M7VC do
        def compute(raw, ctx) do
          "VIEW: #{String.upcase(raw)} for #{ctx.room_name}"
        end
      end
      """

      code_uuid = seed_compute_doc(store, compute_source)

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          code_uuid: code_uuid,
          spec_context: %{room_name: "general"},
          store: store,
          router: router
        )

      :ok =
        wait_until(fn ->
          read_content(store, target_uuid) == "VIEW: HELLO for general"
        end)

      GenServer.stop(pid)
    end

    test "code_uuid commit triggers {:stop, :normal} (restart-the-instance)",
         %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "hello")
      target_uuid = seed_text_doc(store, "")

      compute_source = ~S"""
      defmodule Cp.Test.M7VCRestart do
        def compute(raw, _ctx), do: raw
      end
      """

      code_uuid = seed_compute_doc(store, compute_source)

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          code_uuid: code_uuid,
          spec_context: %{room_name: "alpha"},
          store: store,
          router: router
        )

      Process.monitor(pid)

      send(pid, {:commit, code_uuid, "fake-commit-id", %{}})

      assert_receive {:DOWN, _ref, :process, ^pid, _reason}, 500
    end

    test "init/1 errors when missing compute/2 export in code-doc",
         %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "hello")
      target_uuid = seed_text_doc(store, "")

      bad_compute_source = ~S"""
      defmodule Cp.Test.M7VCNoCompute do
        def something_else, do: :nope
      end
      """

      code_uuid = seed_compute_doc(store, bad_compute_source)

      Process.flag(:trap_exit, true)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ViewCompute.start_link(
            source_uuid: source_uuid,
            target_uuid: target_uuid,
            code_uuid: code_uuid,
            spec_context: %{},
            store: store,
            router: router
          )
        end)

      assert {:error, _} = result
    end

    test "init/1 errors when both :code_uuid and :compute_fn supplied",
         %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "hello")
      target_uuid = seed_text_doc(store, "")

      code_uuid = seed_compute_doc(store, "defmodule X do def compute(_,_), do: :ok end")

      Process.flag(:trap_exit, true)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ViewCompute.start_link(
            source_uuid: source_uuid,
            target_uuid: target_uuid,
            code_uuid: code_uuid,
            compute_fn: fn x -> x end,
            store: store,
            router: router
          )
        end)

      assert {:error, _} = result
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
