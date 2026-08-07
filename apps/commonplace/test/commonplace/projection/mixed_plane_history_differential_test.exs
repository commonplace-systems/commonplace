defmodule Commonplace.Projection.MixedPlaneHistoryDifferentialTest do
  use ExUnit.Case, async: false

  alias Commonplace.Projection
  alias Commonplace.Projection.MixedPlaneHistoryFixture
  alias Commonplace.Store.{Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    suffix = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "mixed-plane-differential-#{suffix}")
    store = :"mixed_plane_differential_#{suffix}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store}
  end

  test "incremental history agrees on a delta chain with an unreachable sibling", %{store: store} do
    {doc_uuid, commit_ids} = seed_delta_chain!(store, 4)

    oracle =
      Enum.map(commit_ids, fn commit_id ->
        {commit_id, Projection.project_at(doc_uuid, commit_id, store: store)}
      end)

    incremental = Projection.project_history(doc_uuid, commit_ids, store: store)

    assert_history_equal(oracle, incremental)
  end

  test "incremental history agrees across every mixed-plane snapshot fixture commit" do
    MixedPlaneHistoryFixture.with_store(fn store, fixture ->
      commit_ids = Enum.sort(fixture.commit_ids)
      assert_incremental_matches_oracle(store, fixture.doc_uuid, commit_ids)
    end)
  end

  test "incremental history preserves malformed-update projection failures", %{store: store} do
    doc_uuid = "differential-malformed-update"
    _commit = CommitStore.create_commit(store, doc_uuid, <<255, 0, 255>>, nil)

    commit_ids =
      store
      |> CommitStore.all_commit_ids_for_doc(doc_uuid)
      |> MapSet.to_list()
      |> Enum.sort()

    assert_incremental_matches_oracle(store, doc_uuid, commit_ids)
  end

  test "incremental history agrees when the chain does not ground at genesis", %{store: store} do
    doc_uuid = "differential-missing-parent"
    {doc, _type} = Doc.get_or_create_type(Doc.new(client_id: 91), "body", :text)
    doc = Text.insert(doc, "body", 0, "orphaned baseline")
    missing_parent = :crypto.strong_rand_bytes(32)
    commit = Commit.new(doc_uuid, Encoding.encode_update(doc), missing_parent)
    db = CommitStore.db_handle(store)
    CubDB.put(db, {:commit, commit.id}, commit)
    :ok = CommitStore.set_latest(store, doc_uuid, commit.id)

    assert_incremental_matches_oracle(store, doc_uuid, [commit.id])
  end

  defp seed_delta_chain!(store, count) do
    doc_uuid = "differential-delta-chain"

    {_doc, _parent, authored_ids} =
      Enum.reduce(1..count, {Doc.new(client_id: 77), nil, []}, fn index, {doc, parent_id, ids} ->
        before = Doc.state_vector(doc)
        {doc, _type} = Doc.get_or_create_type(doc, "body", :text)
        doc = Text.insert(doc, "body", Text.length(doc, "body"), Integer.to_string(index))

        update =
          if parent_id == nil,
            do: Encoding.encode_update(doc),
            else: Encoding.encode_diff(doc, before)

        commit = CommitStore.create_commit(store, doc_uuid, update, parent_id)
        {doc, commit.id, [commit.id | ids]}
      end)

    first_authored_id = List.last(authored_ids)
    {sibling, _type} = Doc.get_or_create_type(Doc.new(client_id: 78), "body", :text)
    sibling = Text.insert(sibling, "body", 0, "abandoned sibling")

    _sibling_commit =
      CommitStore.create_commit(
        store,
        doc_uuid,
        Encoding.encode_update(sibling),
        first_authored_id
      )

    commit_ids =
      store
      |> CommitStore.all_commit_ids_for_doc(doc_uuid)
      |> MapSet.to_list()
      |> Enum.sort()

    {doc_uuid, commit_ids}
  end

  defp assert_history_equal(oracle, incremental) do
    case Enum.zip(oracle, incremental) |> Enum.find(fn {left, right} -> left != right end) do
      nil ->
        assert oracle == incremental

      {{commit_id, expected}, {commit_id, actual}} ->
        flunk(
          "DIFFERENTIAL DIVERGENCE commit=#{hex(commit_id)}\n" <>
            "oracle: #{inspect(expected)}\n" <>
            "incremental: #{inspect(actual)}"
        )
    end
  end

  defp assert_incremental_matches_oracle(store, doc_uuid, commit_ids) do
    oracle =
      Enum.map(commit_ids, fn commit_id ->
        {commit_id, Projection.project_at(doc_uuid, commit_id, store: store)}
      end)

    incremental = Projection.project_history(doc_uuid, commit_ids, store: store)
    assert_history_equal(oracle, incremental)
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
