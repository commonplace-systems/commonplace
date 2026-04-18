defmodule Commonplace.Store.Merger do
  @moduledoc """
  Top-level merge router (CX-fb74 / Build 7.5).

  `merge(store, L, R, strategy: :translate | :merge_snapshot, opts)` is
  a thin dispatch over the two Build 7 merge implementations:

  - `:translate`       → `Commonplace.Store.CrossEpochMerge.merge/4`
    (CX-fdjh / 7.3) — commutes R's post-C edits into L's namespace,
    emitting a `%{kind: :merge}` commit with `parent_id = L` and
    `merge_parents = [R]`.
  - `:merge_snapshot`  → `Commonplace.Store.MergeSnapshotter.build_merge_snapshot/4`
    (CX-dx22 / 7.4) — establishes a fresh namespace both L and R
    derive from, emitting a `%{kind: :snapshot, snapshot_parents:
    [L_ns, R_ns]}` commit.

  Strategy choice is explicit at the call site — no automatic
  heuristics. The router is the seam where later work can layer
  heuristics on top (e.g., "if one side has >N commits since C,
  prefer `:merge_snapshot`"); keeping the decision at the caller
  keeps that future work additive.

  Extra `opts` are forwarded to the chosen strategy unchanged, so
  callers can pass strategy-specific flags (e.g., chain overrides
  used by CrossEpochMerge's adversarial tests) without the router
  needing to know about them.

  ## Red events

  - `[:commonplace, :merge, :completed]` on success, with metadata
    `%{strategy, l, r, result_id}` where `result_id` is the content-
    address of the produced commit.
  - `[:commonplace, :merge, :failed]` on any failure (unknown
    strategy, missing strategy, underlying strategy error), with
    metadata `%{strategy, reason, l, r}`. The underlying
    translate/snapshotter red events (e.g. `[:commonplace,
    :late_edit, :untranslatable]` with `phase: :r_to_c | :c_to_l`)
    still fire from their own modules; this router's `:failed`
    event is the caller-facing summary.
  """

  alias Commonplace.Store.{CrossEpochMerge, MergeSnapshotter}

  @type strategy :: :translate | :merge_snapshot
  @type result :: {:ok, Commonplace.Store.Commit.t()} | {:error, term()}

  @spec merge(GenServer.server(), binary(), binary(), keyword()) :: result()
  def merge(store, l_id, r_id, opts \\ []) when is_binary(l_id) and is_binary(r_id) do
    case Keyword.fetch(opts, :strategy) do
      :error ->
        emit_failed(:strategy_required, nil, l_id, r_id)
        {:error, :strategy_required}

      {:ok, :translate} ->
        dispatch(:translate, l_id, r_id, fn ->
          CrossEpochMerge.merge(store, l_id, r_id, Keyword.delete(opts, :strategy))
        end)

      {:ok, :merge_snapshot} ->
        dispatch(:merge_snapshot, l_id, r_id, fn ->
          MergeSnapshotter.build_merge_snapshot(
            store,
            l_id,
            r_id,
            Keyword.delete(opts, :strategy)
          )
        end)

      {:ok, other} ->
        reason = {:unknown_strategy, other}
        emit_failed(reason, other, l_id, r_id)
        {:error, reason}
    end
  end

  @doc """
  Canonicalize a merge arg pair by CID ordering (CX-1mml).

  Returns `{min_cid, max_cid}` — the smaller CID as the first element,
  regardless of input order. Callers that want byte-deterministic merge
  commits across peers pipe their `(l_id, r_id)` pair through this
  before calling `merge/4`.

  Merger.merge/4 itself does NOT auto-canonicalize because its existing
  callers (notably `SiblingMerger`) rely on a semantic `parent = :latest`
  invariant for their CAS gate — flipping parent/merge_parent would
  break that. Callers with cross-peer determinism requirements opt in
  explicitly.
  """
  @spec canonical_pair(binary(), binary()) :: {binary(), binary()}
  def canonical_pair(a, b) when is_binary(a) and is_binary(b) and a <= b, do: {a, b}
  def canonical_pair(a, b) when is_binary(a) and is_binary(b), do: {b, a}

  defp dispatch(strategy, l_id, r_id, fun) do
    case fun.() do
      {:ok, commit} ->
        emit_completed(strategy, l_id, r_id, commit.id)
        {:ok, commit}

      {:error, reason} = err ->
        emit_failed(reason, strategy, l_id, r_id)
        err
    end
  end

  defp emit_completed(strategy, l_id, r_id, result_id) do
    :telemetry.execute(
      [:commonplace, :merge, :completed],
      %{system_time: System.system_time()},
      %{strategy: strategy, l: l_id, r: r_id, result_id: result_id}
    )
  end

  defp emit_failed(reason, strategy, l_id, r_id) do
    :telemetry.execute(
      [:commonplace, :merge, :failed],
      %{system_time: System.system_time()},
      %{strategy: strategy, reason: reason, l: l_id, r: r_id}
    )
  end
end
