defmodule Commonplace.Code.SourceDocTest do
  @moduledoc """
  CX-i27x (sub-bead i of CX-6on8 M6): substrate-tier compile-from-doc
  primitive. Generalizes Orchestrator's hot_reload_module/start_process
  compile core for substrate consumption.

  Tests cover read/compile/resolve plus the round-1 audit (A) two-ETS-
  table cache invalidation discipline (no stale-entry leak on hash
  change).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_source_doc_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    SourceDoc.reset_cache()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    %{store: CommitStoreClient}
  end

  defp mint_source_doc(source_string) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_source.ex")
    doc = ContentType.insert_text(doc, 0, source_string)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp commit_new_content(uuid, source_string) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_source.ex")
    doc = ContentType.insert_text(doc, 0, source_string)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(uuid, update)
    :ok
  end

  describe "read/2" do
    test "returns content + content_hash for an existing source doc", %{store: store} do
      source = "defmodule Cp.Test1 do\n  def x, do: 42\nend\n"
      uuid = mint_source_doc(source)

      assert {:ok, ^source, hash} = SourceDoc.read(uuid, store)
      assert is_binary(hash)
      assert byte_size(hash) == 16, "MD5 hash is 16 bytes"
    end

    test "returns {:error, :not_found} for a missing UUID", %{store: store} do
      assert {:error, :not_found} = SourceDoc.read(UUID.uuid4(), store)
    end
  end

  describe "compile/2 — happy path" do
    test "compiles source doc into a runtime module", %{store: store} do
      source = """
      defmodule Cp.Test.Compile1 do
        def hello, do: :world
      end
      """

      uuid = mint_source_doc(source)

      assert {:ok, module} = SourceDoc.compile(uuid, store)
      assert module == Cp.Test.Compile1
      assert apply(module, :hello, []) == :world
    end

    test "second compile returns cached module without recompiling (same content_hash)",
         %{store: store} do
      source = """
      defmodule Cp.Test.CacheHit do
        def n, do: 1
      end
      """

      uuid = mint_source_doc(source)

      {:ok, mod1} = SourceDoc.compile(uuid, store)
      {:ok, mod2} = SourceDoc.compile(uuid, store)

      assert mod1 == mod2
    end
  end

  describe "compile/2 — recompile + ETS invalidation discipline (round-1 audit (A))" do
    test "recompiles when content changes (new hash) + cleans up stale ETS entries",
         %{store: store} do
      source_v1 = """
      defmodule Cp.Test.Recompile do
        def value, do: 1
      end
      """

      uuid = mint_source_doc(source_v1)
      {:ok, mod_v1} = SourceDoc.compile(uuid, store)
      assert apply(mod_v1, :value, []) == 1

      source_v2 = """
      defmodule Cp.Test.Recompile do
        def value, do: 2
      end
      """

      :ok = commit_new_content(uuid, source_v2)

      {:ok, mod_v2} = SourceDoc.compile(uuid, store)
      assert apply(mod_v2, :value, []) == 2

      # Round-1 audit (A) — no stale entry leak
      # The :source_doc_index should have exactly one entry for this uuid
      # (the latest hash); the old hash entry should have been deleted.
      index_entries = :ets.match_object(:source_doc_index, {uuid, :_, :_, :_})
      assert length(index_entries) == 1, "no stale uuid entries in index after recompile"
    end
  end

  describe "compile/2 — error paths" do
    test "returns {:error, _} on parse error in source", %{store: store} do
      bad_source = "defmodule UnclosedSyntax do\n  def x, do:"
      uuid = mint_source_doc(bad_source)

      assert {:error, _reason} = SourceDoc.compile(uuid, store)
    end

    test "returns {:error, :not_found} for missing UUID", %{store: store} do
      assert {:error, :not_found} = SourceDoc.compile(UUID.uuid4(), store)
    end
  end

  describe "resolve/3 — DocRef relative-path resolution" do
    setup %{store: store} do
      # Synthetic tree: /test/dir/_compute (spec stub) + /test/dir/_renderer.ex
      # resolve/3 walks `../_renderer.ex` from spec's containing dir.
      renderer_source = """
      defmodule Cp.Test.Resolve do
        def hi, do: "hi from doc"
      end
      """

      renderer_uuid = mint_source_doc(renderer_source)

      # Mint a parent dir schema with renderer entry
      dir_uuid = UUID.uuid4()
      dir_schema = Schema.new_schema()
      dir_schema = Schema.add_file(dir_schema, "_renderer.ex", renderer_uuid)
      update = Yelixer.Encoding.encode_update(dir_schema)
      CommitStore.create_commit(Commonplace.Store.CommitStore, dir_uuid, update, nil)

      # Mint root with the dir entry
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_directory(root_doc, "test", dir_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
      File.write!(Path.join(Application.get_env(:commonplace, :data_dir), "root"), root_uuid)

      _ = store
      %{root_uuid: root_uuid, dir_path: "test", renderer_uuid: renderer_uuid}
    end

    test "resolves '../_renderer.ex' from spec's path → compiled module",
         %{store: store, dir_path: dir_path, renderer_uuid: renderer_uuid} do
      # Spec lives at "/test/dir/_compute" — resolve "../_renderer.ex" from it.
      # context_path is the spec's full path; we walk Path.dirname → join "_renderer.ex"
      spec_path = "#{dir_path}/_compute"

      assert {:ok, module} = SourceDoc.resolve("../_renderer.ex", spec_path, store)
      assert apply(module, :hi, []) == "hi from doc"

      _ = renderer_uuid
    end

    test "returns {:error, :not_found} for missing sibling", %{store: store, dir_path: dir_path} do
      spec_path = "#{dir_path}/_compute"

      assert {:error, :not_found} =
               SourceDoc.resolve("../no_such_file.ex", spec_path, store)
    end
  end

  describe "compile cache cap (R8c / CX-tdkq.8)" do
    setup do
      Application.put_env(:commonplace, :source_doc_cache_max, 2)
      on_exit(fn -> Application.delete_env(:commonplace, :source_doc_cache_max) end)
      :ok
    end

    defp mod_src(n), do: "defmodule Commonplace.UserCode.CapTest.M#{n} do def v, do: #{n} end"

    defp cached_uuids do
      :source_doc_index
    |> :ets.tab2list()
    |> Enum.map(fn {uuid, _h, _cache_key, _a} -> uuid end)
    |> MapSet.new()
    end

    test "evicts least-recently-used modules once over the cap" do
      a = mint_source_doc(mod_src(1))
      b = mint_source_doc(mod_src(2))
      c = mint_source_doc(mod_src(3))

      assert {:ok, _} = SourceDoc.compile(a)
      assert {:ok, _} = SourceDoc.compile(b)
      # Touch A so B is now the least-recently-used of the two.
      assert {:ok, _} = SourceDoc.compile(a)

      # Cache is at the cap (2: A, B). Compiling C must evict the LRU (B).
      assert {:ok, _} = SourceDoc.compile(c)

      assert :ets.info(:source_doc_index, :size) == 2
      uuids = cached_uuids()
      assert MapSet.member?(uuids, a), "A was recently used — should survive"
      assert MapSet.member?(uuids, c), "C was just compiled — should be present"
      refute MapSet.member?(uuids, b), "B was LRU — should have been evicted"

      # Evicted entry recompiles transparently on next access (it's a cache).
      assert {:ok, _} = SourceDoc.compile(b)
      assert :ets.info(:source_doc_index, :size) == 2
    end
  end
end
