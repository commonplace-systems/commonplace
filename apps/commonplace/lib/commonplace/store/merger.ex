defmodule Commonplace.Store.Merger do
  @moduledoc """
  Explicit-choice router for merging two commits (CX-fb74 / Build 7.5).

  A merge reconciles two divergent heads of one document — **L** (left/target)
  and **R** (right/source) — sharing a common ancestor **C**. This module does
  *not* compute the merge; it dispatches to one of two Build 7 engines based on
  a strategy the caller names explicitly:

  - `:translate`       → `Commonplace.Store.CrossEpochMerge.merge/4`
    (CX-fdjh / 7.3) — commutes R's edits since C into L's namespace, so
    L stays the canonical line and R's post-C work is replayed on top.
    The engine emits a `%{kind: :merge}` commit with `parent_id = L`
    and `merge_parents = [R]`.
  - `:merge_snapshot`  → `Commonplace.Store.MergeSnapshotter.build_merge_snapshot/4`
    (CX-dx22 / 7.4) — mints a *fresh* namespace that both L and R derive
    from, privileging neither side. The engine emits a `%{kind: :snapshot,
    snapshot_parents: [L_ns, R_ns]}` commit.

  Both engines *write and return* the commit; this router only chooses
  between them and summarizes the result. The split between the two is
  really about **identity**. A *namespace* is the lineage identity a
  commit's history belongs to — established by genesis, reset by
  snapshots (see `Commonplace.Store.Namespace`). `:translate` keeps L's
  namespace, so L's identity continues and R's post-C edits are
  re-expressed under it; `:merge_snapshot` retires both and mints a new
  identity descending from each. That is exactly why translate is
  asymmetric (one side's identity survives) and merge_snapshot is
  symmetric (neither does).

  ## Choosing a strategy — and why the caller must

  Strategy is explicit at the call site; the router applies **no** heuristics.
  The two engines make opposite trade-offs:

  - `:translate` is asymmetric and cheap — it keeps L's namespace and commutes
    only R's post-C edits across. Best when one side is the canonical line and
    R has few commits since C.
  - `:merge_snapshot` is symmetric and heavier — it abandons both namespaces for
    a fresh one, so neither side's identity wins. Best when both sides have
    diverged far enough that translating one into the other is expensive (the
    translate engine re-commits every one of R's post-C edits, so cost grows with
    R's divergence) or lossy (some cross-namespace edits don't translate — the
    engine raises the `[:commonplace, :late_edit, :untranslatable]` red event
    listed below).

  Forcing the caller to choose keeps the seam additive: a future auto-heuristic
  (e.g. "prefer `:merge_snapshot` when one side has >N commits since C") can
  layer on top without touching existing callers, each of which already states
  its intent. It also lets callers that need a specific emitted shape — notably
  `SiblingMerger`, which requires `parent_id = L` — get exactly that.

  Extra `opts` are forwarded to the chosen engine unchanged, so strategy-specific
  flags (e.g. chain overrides used in CrossEpochMerge adversarial tests) pass
  through without the router knowing them.

  ## Determinism across peers (`canonical_pair/2`)

  `merge/4` does *not* reorder its `(L, R)` pair. The emitted merge commit's
  `parent_id` is L (the first arg), and callers like `SiblingMerger` pass their
  observed `:latest` (the doc's local head pointer in
  `Commonplace.Store.CommitStore`) as L so the merge chains off it — the
  compare-and-swap gate
  they write it through requires `parent_id == :latest`. Reordering could make
  `parent_id` become R ≠ `:latest`, failing that gate. Callers that instead need
  byte-identical merge commits on every peer pipe their pair through
  `canonical_pair/2` first, which sorts by CID so every peer feeds the engine the
  same order (CX-1mml). The opt-in design reflects that a CAS-stable parent and
  cross-peer determinism are conflicting requirements.

  ## Red events

  - `[:commonplace, :merge, :completed]` on success, with metadata
    `%{strategy, l, r, result_id}` where `result_id` is the content-address of
    the produced commit.
  - `[:commonplace, :merge, :failed]` on any failure (unknown strategy, missing
    strategy, engine error), with metadata `%{strategy, reason, l, r}`. The
    engines' own red events (e.g. `[:commonplace, :late_edit, :untranslatable]`
    with `phase: :r_to_c | :c_to_l`) still fire from their modules; this
    router's `:failed` is the caller-facing summary (no `phase` field —
    that detail is engine-level).

  ## Worked example

      # L = main's head, R = a branch head, sharing ancestor C.
      # Branch has only a few commits since C, so translate is cheap.
      {:ok, m} = Merger.merge(store, l_id, r_id, strategy: :translate)
      #   m.metadata.kind == :merge, m.parent_id == l_id,
      #   m.merge_parents == [r_id] — main stays canonical, branch folded in.

      # Both sides diverged heavily → a fresh symmetric namespace instead.
      {:ok, s} = Merger.merge(store, l_id, r_id, strategy: :merge_snapshot)
      #   s.metadata.kind == :snapshot — neither side's namespace wins.

      # No strategy named → hard error plus a :merge.failed red event.
      Merger.merge(store, l_id, r_id)
      #   {:error, :strategy_required}

  ## What this module is NOT

  - **Not the merge engine.** Reconciliation lives in
    `Commonplace.Store.CrossEpochMerge` and
    `Commonplace.Store.MergeSnapshotter`; Merger only picks one and emits the
    outcome as a red event.
  - **Not a heuristic.** It refuses to guess the strategy — that decision is the
    caller's.
  - **Not a canonicalizer by default.** Pair ordering is left as-is unless the
    caller opts into `canonical_pair/2`.
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
