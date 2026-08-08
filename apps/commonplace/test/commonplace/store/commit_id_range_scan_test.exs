defmodule Commonplace.Store.CommitIdRangeScanTest do
  @moduledoc """
  CX-mg8s — `all_commit_ids_for_doc/2` must find commits whose id starts
  with byte 0xFF.

  The scan bounded its CubDB range at `max_key: {:commit, <<255>>}`.
  Commit ids are RAW 32-BYTE binaries, and Erlang compares binaries
  lexicographically with a shorter prefix sorting LOWER — so `<<255>>`
  is a *prefix* of `<<255, ...31 more>>` and therefore SMALLER. Every id
  beginning with 0xFF sorted above the bound and was silently dropped:
  ~1/256 of all commits. Measured live as 2 missing out of 1063 on a
  real document.

  These tests write commit rows DIRECTLY through the db handle rather
  than through `create_commit`, because commit ids are content-addressed
  — you cannot ask for an id that starts with a chosen byte. The point
  of the test is the range arithmetic, not the hashing, so constructing
  the key is the honest way to reach it.

  ⚠️ PRE-DECLARED CONTROL: the 0xFF test MUST fail against the old
  `<<255>>` bound. A test that passes both before and after the fix
  would be worthless here — the whole defect is a scan that cannot see
  part of what it scans while reporting a confident total.
  """
  use ExUnit.Case

  alias Commonplace.Store.CommitStore

  @index_state_key {:doc_commit_index, :state}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_range_scan_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!(Supervisor.child_spec({CommitStore, data_dir: dir, name: name}, id: name))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name, db: CommitStore.db_handle(name), dir: dir}
  end

  # These raw rows deliberately cannot use CommitStore's private commit_rows/1
  # choke: the test must choose the content-addressed id bytes. Marking the
  # index dirty after each seed makes that bypass explicit and exercises the
  # production startup rebuild, instead of quietly duplicating the index-row
  # implementation in test code and teaching future readers that raw writes
  # beside the choke are safe.
  defp put_commit(db, id, doc_uuid) do
    :ok = CubDB.put(db, {:commit, id}, %{doc_uuid: doc_uuid, id: id})
    :ok = CubDB.put(db, @index_state_key, {:dirty, 1, {:range_scan_seed, id}})
    id
  end

  defp rebuild_after_raw_seed(%{store: store, dir: dir}) do
    :ok = stop_supervised(store)

    start_supervised!(Supervisor.child_spec({CommitStore, data_dir: dir, name: store}, id: store))

    store
  end

  defp id_starting_with(byte), do: <<byte>> <> :binary.copy(<<7>>, 31)

  test "finds a commit whose id starts with 0xFF (the regression)", context do
    uuid = "doc-ff"
    ff = put_commit(context.db, id_starting_with(255), uuid)
    store = rebuild_after_raw_seed(context)

    found = CommitStore.all_commit_ids_for_doc(store, uuid)

    assert MapSet.member?(found, ff),
           "a commit id beginning with byte 0xFF was NOT returned by the index scan — " <>
             "the range bound excludes it, so ~1/256 of commits are invisible to every " <>
             "caller that relies on this function to enumerate what exists"
  end

  test "0xFF ids are found alongside ordinary ones, and none are lost", context do
    uuid = "doc-mixed"

    ids =
      for b <- [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF] do
        put_commit(context.db, id_starting_with(b), uuid)
      end

    store = rebuild_after_raw_seed(context)
    found = CommitStore.all_commit_ids_for_doc(store, uuid)

    missing = Enum.reject(ids, &MapSet.member?(found, &1))

    assert missing == [],
           "ids dropped by the range scan, by leading byte: " <>
             inspect(Enum.map(missing, fn <<b, _::binary>> -> "0x#{Base.encode16(<<b>>)}" end))

    assert MapSet.size(found) == length(ids)
  end

  test "an all-0xFF id (the extreme of the range) is still found", context do
    uuid = "doc-max"
    maxi = put_commit(context.db, :binary.copy(<<255>>, 32), uuid)
    store = rebuild_after_raw_seed(context)

    assert MapSet.member?(CommitStore.all_commit_ids_for_doc(store, uuid), maxi)
  end

  describe "all_doc_uuids/1 — the sibling scan, and the gap this suite originally had" do
    # Worth stating plainly: the first version of this file tested ONLY
    # the commit scan. While fixing the bound I introduced a genuine
    # regression in the OTHER scan (`do_all_doc_uuids` read the shared
    # max-key attribute before its definition, making it `nil`, and
    # `nil` sorts BELOW all binaries — so the range collapsed to empty
    # instead of widening). This suite stayed 4/4 GREEN through that,
    # because it never touched the second scan. An existing test
    # elsewhere caught it.
    #
    # So these exist to make the two scans fail together, since they now
    # share one bound: changing it can break either.
    test "returns docs and is not silently empty", %{store: store, db: db} do
      CubDB.put(db, {:latest, "doc-one"}, <<1>>)
      CubDB.put(db, {:latest, "doc-two"}, <<2>>)

      uuids = CommitStore.all_doc_uuids(store)

      assert MapSet.member?(uuids, "doc-one")
      assert MapSet.member?(uuids, "doc-two")

      refute MapSet.size(uuids) == 0,
             "all_doc_uuids returned EMPTY — an over-narrow or inverted range bound " <>
               "collapses this scan rather than widening it, and an empty result is " <>
               "indistinguishable from a store with no documents"
    end

    test "a doc uuid at the top of the byte range is still found", %{store: store, db: db} do
      # Not reachable with today's ASCII UUID strings, but the bound is
      # shared with the commit scan, so pin the property rather than
      # relying on the key format never changing.
      high = <<255, 255, 255>>
      CubDB.put(db, {:latest, high}, <<9>>)

      assert MapSet.member?(CommitStore.all_doc_uuids(store), high)
    end
  end

  test "the scan still excludes other docs' commits", context do
    mine = put_commit(context.db, id_starting_with(255), "doc-a")
    theirs = put_commit(context.db, id_starting_with(254), "doc-b")
    store = rebuild_after_raw_seed(context)

    found = CommitStore.all_commit_ids_for_doc(store, "doc-a")

    assert MapSet.member?(found, mine)

    refute MapSet.member?(found, theirs),
           "widening the range must not make the scan return other documents' commits"
  end
end
