defmodule Commonplace.Projection.MixedPlaneHistoryOwnershipTest do
  @moduledoc """
  BUILD-2a migration-verify (plan #14196): `commit_ids_by_doc/2` must attribute a
  commit to its OWNING doc via the authoritative `{:doc_commit}` index — NOT by
  the `{:commit}` struct's `.doc_uuid` field, which is a debug trace of the first
  writer (excluded from the id hash, stale after forks / shared across an imported
  or convergent id — `commit.ex:52`).

  The discriminating construction: a commit whose STRUCT says doc A, but whose
  `{:doc_commit}` index also lists it under doc B (the cross-doc id-collision the
  measurement flagged — a shared ancestry / imported id). The OLD implementation
  (a full `{:commit}` scan grouped by `struct.doc_uuid`) would give B the EMPTY
  set — the bug. The migrated implementation credits B from the index. So the
  assertion "B gets the shared id" is RED on the struct-`.doc_uuid` basis and
  GREEN on the `{:doc_commit}` basis — a must-find for the fix, not a tautology.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Projection.MixedPlaneHistory
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "mph_ownership_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"mph_ownership_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp db(store), do: :persistent_term.get({CommitStore, :db, store})

  test "attributes a shared commit id to BOTH owning docs, from the index not the struct",
       %{store: store} do
    # doc A owns a real commit (its genesis). The struct's .doc_uuid is "doc-A".
    {:ok, genesis} = CommitStore.ensure_genesis(store, "doc-A")
    shared_id = genesis.id

    assert MapSet.member?(CommitStore.all_commit_ids_for_doc(store, "doc-A"), shared_id)

    # The commit STRUCT records doc-A as its (first) writer — the debug trace.
    {:ok, struct} = CommitStore.get_commit(store, shared_id)
    assert struct.doc_uuid == "doc-A"

    # doc B ALSO owns that id per the authoritative index (the cross-doc collision
    # / imported-id case). Inject the index row directly — the shape a shared id
    # produces — without a second struct (content-addressing dedups the struct).
    CubDB.put(db(store), {:doc_commit, "doc-B", shared_id}, true)

    grouped = MixedPlaneHistory.commit_ids_by_doc(store, ["doc-A", "doc-B"])

    assert MapSet.member?(grouped["doc-A"], shared_id)

    assert MapSet.member?(grouped["doc-B"], shared_id),
           "doc-B did not receive a commit it owns per {:doc_commit} — ownership was taken from the struct's .doc_uuid (=doc-A), the trap this migration removes"
  end

  test "returns exactly the requested docs, empty map for none", %{store: store} do
    {:ok, _g} = CommitStore.ensure_genesis(store, "doc-A")

    assert MixedPlaneHistory.commit_ids_by_doc(store, []) == %{}

    grouped = MixedPlaneHistory.commit_ids_by_doc(store, ["doc-A", "doc-absent"])
    assert Map.keys(grouped) |> Enum.sort() == ["doc-A", "doc-absent"]
    assert MapSet.size(grouped["doc-A"]) >= 1
    assert grouped["doc-absent"] == MapSet.new()
  end
end
