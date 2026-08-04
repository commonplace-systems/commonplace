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

    test "CX-vt9l.2: carries a derivation record alongside last_computed_at, additive", %{
      store: store,
      router: router
    } do
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
      :ok = wait_until(fn -> ViewCompute.state(pid).derivation_record != nil end)

      state = ViewCompute.state(pid)
      # last_computed_at is untouched by the adoption — still set exactly
      # as before.
      assert %DateTime{} = state.last_computed_at

      record = state.derivation_record
      assert Commonplace.DerivationRecord.witness?(record)
      assert %{^source_uuid => _commit_id} = record["sources_pin"]
      assert {^target_uuid, _commit_id} = record["output"]
      assert Commonplace.DerivationRecord.stale?(record, store) == :current

      GenServer.stop(pid)
    end
  end

  # CX-pcn4 (M7 sub-bead v): seed helpers retained for the M7 :code_uuid
  # describe block (below). The M5 :spec_uuid + M6 <function ref>
  # describe blocks are RETIRED — substrate Commonplace.View.ComputeSpec
  # is gone; the only surviving path is M7 ComputeRunner via :code_uuid.
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
