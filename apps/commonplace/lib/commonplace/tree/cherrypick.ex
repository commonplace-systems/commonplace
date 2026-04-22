defmodule Commonplace.Tree.Cherrypick do
  @moduledoc """
  Cherry-pick commits across branches (CX-b70).

  Takes a source commit_id and a target doc_uuid. Extracts the DELTA
  the source commit introduced — the ops present in the source but not
  in its parent — and applies that delta to the target's current
  state. The resulting commit on the target encodes the full merged
  state (so readers via `reconstruct_snapshot/2` see everything), while
  its content is exactly what you'd get by pulling the source commit's
  changes in isolation.

  Yjs CRDT semantics make cherry-pick idempotent and commutative: a
  second cherry-pick of the same source is a no-op on observable
  content, and cherry-picking in different orders converges on the
  same state.

  Algorithm:
    1. Fetch source commit + its parent (if any).
    2. Rebuild source doc; compute state vector of the source's parent.
    3. `encode_diff(source_doc, parent_sv)` → delta update bytes. If
       the source has no parent (nil or missing), delta = source.update.
    4. Load target's current state; apply the delta.
    5. Encode the combined state + write a chained commit on target.
  """

  alias Commonplace.Store.{CommitStore, Commit}
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{BlockStore, Doc, Encoding, StateVector}

  @type result ::
          {:ok, Commit.t()}
          | {:error, :source_commit_not_found}
          | {:error, term()}

  @spec cherrypick(GenServer.server(), binary(), String.t()) :: result()
  def cherrypick(store, source_commit_id, target_uuid)
      when is_binary(source_commit_id) and is_binary(target_uuid) do
    with {:ok, source_commit} <- fetch_source(store, source_commit_id),
         {:ok, source_doc} <- reconstruct(store, source_commit.doc_uuid, source_commit.id),
         {:ok, delta} <- compute_delta(store, source_commit, source_doc),
         {:ok, merged_doc} <- apply_onto_target(store, target_uuid, delta) do
      update = Encoding.encode_update(merged_doc)
      commit = CommitStore.create_chained_commit(store, target_uuid, update)
      {:ok, commit}
    end
  end

  defp fetch_source(store, source_commit_id) do
    case CommitStore.get_commit(store, source_commit_id) do
      {:ok, commit} -> {:ok, commit}
      _ -> {:error, :source_commit_not_found}
    end
  end

  defp reconstruct(store, uuid, commit_id) do
    case DocBuilder.reconstruct_doc_at(store, uuid, commit_id) do
      {:ok, doc} -> {:ok, doc}
      :none -> {:error, :source_reconstruct_failed}
    end
  end

  # Source's delta = ops it introduced on top of its parent. If the
  # source has no parent (genesis-adjacent or orphan), the "delta" is
  # the source's full update bytes.
  defp compute_delta(_store, %Commit{parent_id: nil} = source, _source_doc) do
    {:ok, source.update}
  end

  defp compute_delta(store, %Commit{parent_id: parent_id} = source, source_doc) do
    parent_sv =
      case DocBuilder.reconstruct_doc_at(store, source.doc_uuid, parent_id) do
        {:ok, parent_doc} -> BlockStore.state_vector(parent_doc.store)
        :none -> StateVector.new()
      end

    {:ok, Encoding.encode_diff(source_doc, parent_sv)}
  end

  defp apply_onto_target(store, target_uuid, delta) do
    base =
      case CommitStore.latest_commit(store, target_uuid) do
        {:ok, latest_commit} ->
          doc = Doc.new()
          case Encoding.apply_update(doc, latest_commit.update) do
            {:ok, d} -> d
            {:error, _} -> Doc.new()
          end

        :none ->
          Doc.new()
      end

    Encoding.apply_update(base, delta)
  end
end
