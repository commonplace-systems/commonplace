defmodule Commonplace.Projection.MixedPlaneHistoryFixture do
  @moduledoc false

  alias Commonplace.Projection
  alias Commonplace.Store.{CommitBuilder, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap}

  @source_doc_uuid "235d73b5-a44a-44de-91ad-a753c61f7407"
  @source_commit_prefix "5042f340"

  @doc false
  def source_control,
    do: %{doc_uuid: @source_doc_uuid, commit_prefix: @source_commit_prefix, name: "metadata"}

  @doc false
  def with_store(fun) when is_function(fun, 2) do
    suffix = System.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "commonplace-mixed-plane-control-#{suffix}")
    name = {:global, {__MODULE__, suffix}}

    File.mkdir_p!(dir)
    {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)

    try do
      fixture = seed!(name)
      fun.(name, fixture)
    after
      GenServer.stop(pid)
      File.rm_rf!(dir)
    end
  end

  @doc false
  def contrast do
    with_store(fn store, fixture ->
      {:ok, head} = CommitStore.latest_commit(store, fixture.doc_uuid)
      head_result = Projection.project_at(fixture.doc_uuid, head.id, store: store)

      historical_results =
        store
        |> CommitStore.all_commit_ids_for_doc(fixture.doc_uuid)
        |> Enum.sort()
        |> Enum.map(fn commit_id ->
          {commit_id, Projection.project_at(fixture.doc_uuid, commit_id, store: store)}
        end)

      hits =
        Enum.filter(historical_results, fn
          {_commit_id, {:unknown, {:mixed_plane, _details}}} -> true
          _ -> false
        end)

      %{
        fixture: fixture,
        head_result: head_result,
        historical_results: historical_results,
        hits: hits
      }
    end)
  end

  defp seed!(store) do
    db = CommitStore.db_handle(store)

    # Suppress ordinary first-write genesis insertion so this reproduces the
    # source incident's five-pin shape. Even this scratch-only temporary
    # head assignment goes through the production head-advance choke.
    :ok = CommitStore.set_latest(store, @source_doc_uuid, "fixture-seed-sentinel")

    docs = [
      clean_doc("before"),
      mixed_doc(),
      clean_doc("after-1"),
      clean_doc("after-2"),
      clean_doc("head")
    ]

    {commits, _parent_id} =
      Enum.map_reduce(docs, nil, fn doc, parent_id ->
        commit =
          CommitBuilder.build(
            db,
            @source_doc_uuid,
            Encoding.encode_update(doc),
            parent_id,
            %{kind: :snapshot},
            post_state: doc,
            signing_context: :unsigned
          ).commit

        CubDB.put(db, {:commit, commit.id}, commit)
        {commit, commit.id}
      end)

    head = List.last(commits)
    :ok = CommitStore.set_latest(store, @source_doc_uuid, head.id)

    %{
      doc_uuid: @source_doc_uuid,
      armed_commit_id: commits |> Enum.at(1) |> Map.fetch!(:id),
      commit_ids: Enum.map(commits, & &1.id),
      head_commit_id: head.id,
      source_commit_prefix: @source_commit_prefix
    }
  end

  defp clean_doc(content) do
    doc = Doc.new(client_id: 101)
    {doc, _} = Doc.get_or_create_type(doc, "shared", :text)
    Text.insert(doc, "shared", 0, content)
  end

  defp mixed_doc do
    doc = Doc.new(client_id: 202)
    {doc, _} = Doc.get_or_create_type(doc, "shared", :map)
    doc = YMap.set(doc, "shared", "legacy_field", "residue")
    {doc, _} = Doc.get_or_create_type(doc, "shared", :map)
    Text.insert(doc, "shared", 0, "later text")
  end
end
