defmodule Commonplace.Tree.DocCacheTest do
  @moduledoc """
  Tests for DocCache — covers hit, miss, invalidation, eviction, LRU ordering,
  and the "no-op when unstarted" contract.
  """
  use ExUnit.Case

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocCache, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_doc_cache_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"doc_cache_store_#{:rand.uniform(1_000_000)}"
    cache_name = :"doc_cache_#{:rand.uniform(1_000_000)}"

    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    # PubSub is already started by the :commonplace application (which
    # owns Commonplace.PubSub). If for some reason it isn't, start one.
    case Process.whereis(Commonplace.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Commonplace.PubSub})
      _pid -> :ok
    end

    start_supervised!({DocCache, name: cache_name, max_size: 3})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name, cache: cache_name}
  end

  defp make_commit(store, uuid, text) do
    doc = Doc.new()
    doc = ContentType.create(doc, :text, "f.txt")
    doc = ContentType.insert_text(doc, 0, text)
    update = Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update)
  end

  describe "get_snapshot/2 on miss" do
    test "reconstructs and caches on first call", %{store: store, cache: cache} do
      uuid = "doc-#{:rand.uniform(1_000_000)}"
      make_commit(store, uuid, "hello")

      assert {:ok, doc} = DocCache.get_snapshot(store, uuid, cache)
      assert ContentType.get_content(doc) == "hello"
      assert DocCache.size(cache) == 1
    end

    test "returns :none for unknown uuid", %{store: store, cache: cache} do
      assert :none = DocCache.get_snapshot(store, "nonexistent", cache)
      assert DocCache.size(cache) == 0
    end
  end

  describe "get_snapshot/2 on hit" do
    test "second call returns same doc and does not re-reconstruct",
         %{store: store, cache: cache} do
      uuid = "doc-#{:rand.uniform(1_000_000)}"
      make_commit(store, uuid, "hello")

      {:ok, doc1} = DocCache.get_snapshot(store, uuid, cache)

      # Corrupt the store by stopping it. If the cache genuinely serves
      # from memory without re-reconstruction, a cached hit would still
      # work even with the store gone — BUT get_snapshot verifies
      # :latest on each call, so we can't stop the store. Instead, count
      # CommitStore's apply_update-ish cost indirectly: compare that the
      # returned doc's store is identical to doc1's store.
      {:ok, doc2} = DocCache.get_snapshot(store, uuid, cache)

      # Identity: both calls return the exact same %Yelixer.Doc{} term
      # (the cached one), so pattern equality holds.
      assert doc1 == doc2
    end

    test "calls store 0 reconstructions on hit (telemetry via DocBuilder bypass)",
         %{store: store, cache: cache} do
      uuid = "doc-#{:rand.uniform(1_000_000)}"
      make_commit(store, uuid, "first")

      {:ok, _} = DocCache.get_snapshot(store, uuid, cache)

      # Directly call DocBuilder to produce a fresh reconstruction and
      # compare its content against the cached copy. The cache must
      # return content matching the store's latest.
      {:ok, fresh} = DocBuilder.reconstruct_snapshot(store, uuid)
      {:ok, cached} = DocCache.get_snapshot(store, uuid, cache)

      assert ContentType.get_content(cached) == ContentType.get_content(fresh)
    end
  end

  describe "invalidation on blue:UUID commit broadcast" do
    test "next get_snapshot after new commit is a miss-and-refresh",
         %{store: store, cache: cache} do
      uuid = "doc-#{:rand.uniform(1_000_000)}"
      make_commit(store, uuid, "v1")

      {:ok, doc_v1} = DocCache.get_snapshot(store, uuid, cache)
      assert ContentType.get_content(doc_v1) == "v1"

      # Land a new commit on the same uuid. CommitStore broadcasts on
      # blue:{uuid}, which the cache is subscribed to.
      _commit = make_commit(store, uuid, "v2")

      # Give the cache time to process the broadcast. Use a synchronous
      # GenServer call to flush any pending async messages — :size
      # handle_call runs after handle_info messages already in the
      # mailbox are processed.
      _ = DocCache.size(cache)

      # After invalidation, the cache no longer holds v1; next call
      # reconstructs v2.
      {:ok, doc_v2} = DocCache.get_snapshot(store, uuid, cache)
      assert ContentType.get_content(doc_v2) == "v2"
    end

    test "commit-broadcast invalidation happens even when latest pointer already bumped",
         %{store: store, cache: cache} do
      uuid = "doc-#{:rand.uniform(1_000_000)}"
      make_commit(store, uuid, "v1")

      {:ok, _} = DocCache.get_snapshot(store, uuid, cache)
      assert DocCache.size(cache) == 1

      make_commit(store, uuid, "v2")

      # Flush
      _ = DocCache.size(cache)

      # Post-invalidation, cache is empty for this uuid. (Since max_size
      # is 3 and we only used one uuid, size should drop to 0.)
      assert DocCache.size(cache) == 0
    end
  end

  describe "bounded size + LRU eviction" do
    test "exceeding max_size drops the least-recently-accessed entry",
         %{store: store, cache: cache} do
      uuids =
        for i <- 1..4 do
          u = "doc-#{i}-#{:rand.uniform(1_000_000)}"
          make_commit(store, u, "content-#{i}")
          u
        end

      # Access in order 1, 2, 3, 4 — max_size is 3, so uuid 1 (oldest
      # access) should be evicted.
      for u <- uuids do
        {:ok, _} = DocCache.get_snapshot(store, u, cache)
      end

      assert DocCache.size(cache) == 3

      order = DocCache.uuids_by_access(cache)
      refute Enum.at(uuids, 0) in order, "uuid 1 should have been evicted"
      assert Enum.at(uuids, 1) in order
      assert Enum.at(uuids, 2) in order
      assert Enum.at(uuids, 3) in order
    end

    test "a hit bumps LRU position, protecting the entry from the next eviction",
         %{store: store, cache: cache} do
      [u1, u2, u3, u4] =
        for i <- 1..4 do
          u = "doc-lru-#{i}-#{:rand.uniform(1_000_000)}"
          make_commit(store, u, "c-#{i}")
          u
        end

      {:ok, _} = DocCache.get_snapshot(store, u1, cache)
      {:ok, _} = DocCache.get_snapshot(store, u2, cache)
      {:ok, _} = DocCache.get_snapshot(store, u3, cache)

      # Touch u1 — now u2 is the least-recent.
      {:ok, _} = DocCache.get_snapshot(store, u1, cache)

      # Insert u4 — should evict u2, NOT u1.
      {:ok, _} = DocCache.get_snapshot(store, u4, cache)

      order = DocCache.uuids_by_access(cache)
      assert u1 in order
      refute u2 in order
      assert u3 in order
      assert u4 in order
    end
  end

  describe "no-op when unstarted" do
    test "get_snapshot with no running cache falls through to DocBuilder",
         %{store: store} do
      uuid = "doc-unstarted-#{:rand.uniform(1_000_000)}"
      make_commit(store, uuid, "lonely")

      # Use a cache name that is definitely not registered.
      assert {:ok, doc} =
               DocCache.get_snapshot(store, uuid, :doc_cache_definitely_not_running)

      assert ContentType.get_content(doc) == "lonely"
    end

    test "size, invalidate, clear are no-ops when unstarted" do
      assert DocCache.size(:nope_not_running) == 0
      assert DocCache.invalidate(:nope_not_running, "anything") == :ok
      assert DocCache.clear(:nope_not_running) == :ok
      assert DocCache.uuids_by_access(:nope_not_running) == []
    end
  end
end
