defmodule Commonplace.Store.Snapshotter do
  @moduledoc """
  Builds snapshot payloads: a deterministic Yjs update plus a
  derivation map from new item ids back to the source items they came
  from (CX-6sc / CX-bgy build 5).

  The snapshot update itself is produced by `Yelixer.Doc.snapshot_update/1`,
  which is byte-deterministic across Yelixer instances that hold the
  same logical state (verified by `Yelixer.SnapshotDeterminismTest`).

  The derivation map is `%{source_snapshot_hash => %{new_id => old_id}}`
  where ids are `{client_id, clock}` tuples. For MVP (single-parent
  snapshots) there is exactly one top-level key; the late-edit
  translation pipeline (build 6) will compose these maps across epochs.
  """

  @snapshotter_version 1

  @doc "The current snapshotter version tag (binds into the commit id)."
  def snapshotter_version, do: @snapshotter_version

  @doc """
  Build a complete snapshot payload (update bytes + umbrella metadata)
  for `doc_uuid` with `parent_commit` as the snapshot's source state.

  Reconstructs the doc from history, runs it through the deterministic
  snapshotter, wraps the derivation map under the parent's
  `current_namespace` key, and stamps the current snapshotter version.
  Callers combine the returned `{update_bytes, metadata}` with a
  content-addressed write (signed commit / CAS write / etc.).

  Both `CommitStore.snapshot/2` and `Commonplace.SnapshotTrigger`
  route through this so they agree on payload bytes (load-bearing for
  deterministic-anyone — CX-umz).
  """
  @spec build_snapshot(GenServer.server(), String.t(), Commonplace.Store.Commit.t()) ::
          {binary(), map()}
  def build_snapshot(server, doc_uuid, parent_commit) do
    source_doc = reconstruct_source(server, doc_uuid, parent_commit)
    {update_bytes, dm_inner} = build(source_doc)

    parent_namespace =
      Commonplace.Store.Namespace.current_namespace(parent_commit) || parent_commit.id

    metadata = %{
      snapshot_parents: [parent_namespace],
      derivation_map: %{parent_namespace => dm_inner},
      snapshotter_version: snapshotter_version()
    }

    {update_bytes, metadata}
  end

  defp reconstruct_source(_server, _uuid, %{metadata: %{kind: :genesis}}) do
    Yelixer.Doc.new()
  end

  defp reconstruct_source(server, uuid, _parent) do
    case Commonplace.Tree.DocBuilder.reconstruct_doc(server, uuid) do
      {:ok, doc} -> doc
      :none -> Yelixer.Doc.new()
    end
  end

  @doc """
  Build a snapshot payload from a source Yelixer doc.

  Returns `{update_bytes, derivation_map_inner}`. The caller is
  responsible for wrapping the inner map under the source snapshot
  hash key when assembling metadata.
  """
  @spec build(Yelixer.Doc.t()) :: {binary(), %{optional(tuple()) => tuple()}}
  def build(%Yelixer.Doc{} = source) do
    # `Yelixer.Doc.new/1` picks a random client_id when one isn't
    # specified, and `snapshot_update/1` uses the source doc's
    # client_id as the minter for the fresh doc's items. To get the
    # deterministic-anyone property we need two independent
    # reconstructions of the same logical state to produce the same
    # snapshot bytes — so overwrite `source.client_id` with a
    # deterministic function of the source's observable state before
    # running the replay.
    deterministic = %{source | client_id: deterministic_client_id(source)}
    update_bytes = Yelixer.Doc.snapshot_update(deterministic)

    # Decode the snapshot bytes back into a doc. Its items are the
    # canonical "new" ids the derivation map keys on. Decoding (rather
    # than reusing the intermediate rebuilt doc from inside
    # `snapshot_update/1`) gives us exactly the state a peer will see
    # after applying this snapshot, so coverage is guaranteed.
    {:ok, new_doc} = Yelixer.Encoding.apply_update(Yelixer.Doc.new(), update_bytes)

    source_ids = collect_item_ids(source)
    new_ids = collect_item_ids(new_doc)
    {update_bytes, pair_ids(new_ids, source_ids)}
  end

  # Flatten item ids across the doc in a deterministic order:
  #   clients sorted by id descending, items per client by clock ascending.
  # Matches `Yelixer.Encoding.encode_update/1`'s iteration order so the
  # derivation map is stable across runs and instances.
  defp collect_item_ids(%Yelixer.Doc{store: store}) do
    store.clients
    |> Enum.sort_by(fn {client, _} -> client end, :desc)
    |> Enum.flat_map(fn {_client, items} ->
      items
      |> Enum.sort_by(fn item -> item.id.clock end)
      |> Enum.map(fn item -> {item.id.client, item.id.clock} end)
    end)
  end

  # Pair each new id with a source id at the same position. If new has
  # more items than source (extremely rare — snapshots consolidate, not
  # split), tail new ids reuse the last source id. If source is empty,
  # so must new be, yielding an empty map.
  defp pair_ids([], _source_ids), do: %{}
  defp pair_ids(_new_ids, []), do: %{}

  defp pair_ids(new_ids, source_ids) do
    last = List.last(source_ids)
    source_tuple = List.to_tuple(source_ids)
    source_len = tuple_size(source_tuple)

    new_ids
    |> Enum.with_index()
    |> Map.new(fn {new_id, idx} ->
      src = if idx < source_len, do: elem(source_tuple, idx), else: last
      {new_id, src}
    end)
  end

  # Deterministic client_id for the snapshot doc: the smallest
  # client_id present in the source's items, or 0 if the source is
  # empty. Smallest-by-integer is stable across BEAM nodes and doesn't
  # depend on map iteration order.
  defp deterministic_client_id(%Yelixer.Doc{store: store}) do
    case Map.keys(store.clients) do
      [] -> 0
      clients -> Enum.min(clients)
    end
  end
end
