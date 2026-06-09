defmodule Commonplace.Store.MergePolicy do
  @moduledoc """
  Policy layer that picks a merge strategy so callers don't have to
  (CX-csmr).

  `Commonplace.Store.Merger.merge/4` forces every caller to name
  `:translate` or `:merge_snapshot` — it is the mechanism and takes no
  position on which is right. MergePolicy is the counterpart Merger
  anticipated (its "later work can layer heuristics on top" seam): a thin
  wrapper that resolves a strategy from configurable policy, emits a
  telemetry event recording *why*, then delegates to `Merger`. Merger is
  the mechanism; this module is the decision.

  For what the two strategies do and when each is right, see
  `Commonplace.Store.Merger`'s "Choosing a strategy" section. In short:
  `:translate` keeps L's namespace and replays R's edits into it;
  `:merge_snapshot` mints a fresh namespace both sides derive from.

  ## Resolution order

  First matching rule wins:

  1. **Explicit** — `opts[:strategy]` wins unconditionally. Reason:
     `:explicit`. The override lets callers who know better (tests,
     CLI `--strategy`, context-aware programmatic callers) bypass policy
     entirely.
  2. **Doc-type config** — `opts[:doc_type]` is looked up in
     `Application.get_env(:commonplace, :merge_policy_by_doc_type, %{})`.
     A strategy mapped for that type is used. Reason: `:doc_type_config`.
     Presence docs typically map to `:merge_snapshot` (frequent churn, so
     a cheap epoch reset beats translating a long tail of edits), while
     authoritative docs stay on `:translate` (namespace continuity
     matters).
  3. **State-vector threshold** — if L's namespace has accumulated ≥
     threshold distinct client IDs, use `:merge_snapshot` to reset the
     epoch. Reason: `:sv_threshold`. (A *state vector* is the per-client
     clock summary a CRDT namespace carries — one entry per client that
     has ever written into it. It only grows; a namespace touched by
     thousands of clients drags a large SV through every future merge
     and sync. `:merge_snapshot` starts a fresh namespace, shedding that
     weight.) Threshold defaults to
     `Application.get_env(:commonplace, :merge_snapshot_sv_threshold,
     1000)`, overridable per-call via `opts[:sv_threshold]`. The anchor
     is deliberately **L**, not R: `:translate` produces a commit in L's
     namespace, so L's SV is the one to keep from bloating — checking R
     would optimize the wrong side. Replaying R's edits doesn't change
     that calculus: the merge commit lands in L's namespace, so it is
     L's client-id set that carries forward and keeps accumulating
     across repeated merges — R is just the transient right-hand side
     of one merge.
  4. **Default** — `:translate`. Reason: `:default`.

  ## Telemetry

  Every invocation emits `[:commonplace, :merge, :strategy_selected]`
  with metadata `%{strategy, reason, l, r}` *before* delegating. The
  `reason` tag lets observers bucket by cause — how often does the
  threshold fire vs. explicit overrides vs. doc-type config?
  `Merger.merge/4` still emits its own `:completed` / `:failed` events;
  `:strategy_selected` is additive, not a replacement.

  ## Worked example

      # No strategy, no doc_type, L's namespace small → falls to default.
      MergePolicy.merge(store, l_id, r_id)
      #   → :translate, reason :default

      # L's namespace has seen >1000 clients → threshold fires.
      MergePolicy.merge(store, l_id, r_id)
      #   → :merge_snapshot, reason :sv_threshold

      # Caller forces the strategy; policy is bypassed at rule 1.
      MergePolicy.merge(store, l_id, r_id, strategy: :translate)
      #   → :translate, reason :explicit

  ## What this module is NOT

  - **Not the merge mechanism.** It chooses a strategy and delegates;
    `Commonplace.Store.Merger` (and the engines below it) do the merge.
  - **Not the state-vector source.** L's client-id set comes from
    `Commonplace.Store.Namespace.namespace_client_ids/2`; this module
    only compares its size to the threshold.
  """

  alias Commonplace.Store.{Merger, Namespace}

  @default_sv_threshold 1000

  @type reason :: :explicit | :doc_type_config | :sv_threshold | :default
  @type result :: Merger.result()

  @spec merge(GenServer.server(), binary(), binary(), keyword()) :: result()
  def merge(store, l_id, r_id, opts \\ []) when is_binary(l_id) and is_binary(r_id) do
    {strategy, reason} = resolve_strategy(store, l_id, opts)

    emit_strategy_selected(strategy, reason, l_id, r_id)

    Merger.merge(store, l_id, r_id, Keyword.put(opts, :strategy, strategy))
  end

  # Priority order: explicit → doc_type_config → sv_threshold → default.
  defp resolve_strategy(store, l_id, opts) do
    cond do
      match?({:ok, _}, Keyword.fetch(opts, :strategy)) ->
        {Keyword.fetch!(opts, :strategy), :explicit}

      (dt_strategy = lookup_doc_type(opts)) != nil ->
        {dt_strategy, :doc_type_config}

      over_sv_threshold?(store, l_id, opts) ->
        {:merge_snapshot, :sv_threshold}

      true ->
        {:translate, :default}
    end
  end

  defp lookup_doc_type(opts) do
    case Keyword.fetch(opts, :doc_type) do
      {:ok, dt} ->
        :commonplace
        |> Application.get_env(:merge_policy_by_doc_type, %{})
        |> Map.get(dt)

      :error ->
        nil
    end
  end

  defp over_sv_threshold?(store, l_id, opts) do
    threshold = resolve_threshold(opts)

    case Namespace.namespace_client_ids(store, l_id) do
      {:ok, set} -> MapSet.size(set) >= threshold
      _ -> false
    end
  end

  defp resolve_threshold(opts) do
    Keyword.get(
      opts,
      :sv_threshold,
      Application.get_env(:commonplace, :merge_snapshot_sv_threshold, @default_sv_threshold)
    )
  end

  defp emit_strategy_selected(strategy, reason, l_id, r_id) do
    :telemetry.execute(
      [:commonplace, :merge, :strategy_selected],
      %{system_time: System.system_time()},
      %{strategy: strategy, reason: reason, l: l_id, r: r_id}
    )
  end
end
