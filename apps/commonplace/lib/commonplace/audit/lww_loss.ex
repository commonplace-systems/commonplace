defmodule Commonplace.Audit.LwwLoss do
  @moduledoc """
  CX-tdkq.30: audit persisted commit chains for Find-1 (14520f7) LWW
  map-overwrite loss.

  Pre-fix yelixer encoded map/attribute overwrites with `origin: nil`.
  Those bytes are persisted in commit updates, so even after the
  writer-side fix, replaying an affected chain still tombstones the
  causally-latest write as a "concurrent loser" and the key reads nil.

  Detection principle: the commit chain itself is the causal oracle.
  For every map-key write (any decoded item with a `parent_sub`), the
  causally-latest write in chain order is expected to be visible in the
  reconstructed doc — unless a same-or-later commit's delete-set covers
  it (an intentional delete). A causally-latest write that ends up
  tombstoned WITHOUT delete-set coverage is exactly the Find-1 conflict-
  resolution auto-delete, and cannot be produced by a legitimate delete
  (those always travel via the delete-set).

  Both views are checked:

    * `:full_replay` — every regular commit applied from genesis,
      ignoring snapshots (the raw history as written).
    * `:production` — `DocBuilder.reconstruct_doc/2`, i.e. what readers
      actually see (snapshot-trimmed; a pre-fix snapshot may have baked
      the loss in).

  Read-only, but `reconstruct_doc/2` can opportunistically fire a
  background snapshot — callers auditing a live store should either run
  against a copy or disable `:reader_lazy_snapshot_enabled` first.
  """

  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{DeleteSet, Doc, Encoding, Item}

  @type status :: :visible | :tombstoned | :missing | :skipped
  @type finding :: %{
          key: {term(), String.t()},
          expected_content: term(),
          expected_id: Yelixer.ID.t(),
          commit_id: String.t(),
          full_replay: status(),
          production: status()
        }

  @doc """
  Audit every doc in the store. Returns `{:ok, %{uuid => [finding]}}`
  containing only docs with at least one finding.

  Options:

    * `:full_replay` (default `true`) — also replay the complete regular
      history from genesis. On stores with long text chains this is
      O(n²) in yelixer today (CX-w1fw; a 49MB store did not finish in
      2h41m), so large-store audits should pass `full_replay: false`
      and rely on the production (reader-visible) view; findings then
      carry `full_replay: :skipped`.
  """
  @spec audit_store(GenServer.server(), keyword()) :: {:ok, %{String.t() => [finding()]}}
  def audit_store(store, opts \\ []) do
    findings =
      for uuid <- CommitStoreClient.all_doc_uuids(store),
          {:ok, fs} = audit_doc(store, uuid, opts),
          fs != [],
          into: %{} do
        {uuid, fs}
      end

    {:ok, findings}
  end

  @doc """
  Audit one doc's chain. Returns `{:ok, [finding]}` (empty when clean).
  Takes the same options as `audit_store/2`.
  """
  @spec audit_doc(GenServer.server(), String.t(), keyword()) :: {:ok, [finding()]}
  def audit_doc(store, uuid, opts \\ []) do
    commits =
      CommitStoreClient.commit_log(store, uuid, limit: CommitStore.max_commit_log_limit())
      |> Enum.reverse()
      |> Enum.reject(&kind?(&1, :genesis))

    regular = Enum.reject(commits, &kind?(&1, :snapshot))
    decoded = decode_commits(regular)

    writes = causal_writes(decoded)
    deletes = Enum.map(decoded, fn {pos, commit, _items, ds} -> {pos, commit, ds} end)

    full_replay = if Keyword.get(opts, :full_replay, true), do: replay(regular), else: :skipped
    production = reconstruct_production(store, uuid)

    findings =
      for {key, w} <- writes,
          not intentionally_deleted?(deletes, w),
          status_full = replay_status(full_replay, w.id),
          status_prod = item_status(production, w.id),
          status_full not in [:visible, :skipped] or status_prod != :visible do
        %{
          key: key,
          expected_content: content_value(w.content),
          expected_id: w.id,
          commit_id: w.commit_id,
          full_replay: status_full,
          production: status_prod
        }
      end

    {:ok, Enum.sort_by(findings, & &1.key)}
  end

  defp kind?(commit, kind) do
    match?(%{kind: ^kind}, Map.get(commit, :metadata))
  end

  defp decode_commits(commits) do
    commits
    |> Enum.with_index()
    |> Enum.flat_map(fn {commit, pos} ->
      case Encoding.decode_update(commit.update) do
        {:ok, {items, ds, _rest}} -> [{pos, commit, items, ds}]
        {:error, _} -> []
      end
    end)
  end

  # Last write per {parent, key} in chain order. Tombstone-content items
  # ({:deleted, _} / {:gc, _}) are not writes.
  defp causal_writes(decoded) do
    for {pos, commit, items, _ds} <- decoded,
        %Item{parent_sub: sub} = item <- items,
        is_binary(sub),
        not tombstone_content?(item.content),
        reduce: %{} do
      acc ->
        Map.put(acc, {parent_key(item.parent), sub}, %{
          id: item.id,
          content: item.content,
          pos: pos,
          commit_id: commit.id
        })
    end
  end

  defp tombstone_content?({:deleted, _}), do: true
  defp tombstone_content?({:gc, _}), do: true
  defp tombstone_content?(_), do: false

  defp parent_key({:named, name}), do: name
  defp parent_key(other), do: other

  # A delete-set entry covering the expected item, in the same commit or
  # later, means the key was deleted on purpose after (or with) the write.
  defp intentionally_deleted?(deletes, w) do
    Enum.any?(deletes, fn {pos, _commit, ds} ->
      pos >= w.pos and DeleteSet.deleted?(ds, w.id.client, w.id.clock)
    end)
  end

  defp replay(commits) do
    Enum.reduce_while(commits, Doc.new(), fn commit, doc ->
      case Encoding.apply_update(doc, commit.update) do
        {:ok, doc} -> {:cont, doc}
        _ -> {:halt, doc}
      end
    end)
  end

  defp reconstruct_production(store, uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  defp replay_status(:skipped, _id), do: :skipped
  defp replay_status(doc, id), do: item_status(doc, id)

  defp item_status(nil, _id), do: :missing

  defp item_status(%Doc{} = doc, id) do
    case Doc.get_item(doc, id) do
      nil -> :missing
      %Item{deleted: true} -> :tombstoned
      %Item{content: content} -> if tombstone_content?(content), do: :tombstoned, else: :visible
    end
  end

  defp content_value({:any, [value]}), do: value
  defp content_value(other), do: other
end
