defmodule Commonplace.Store.MergePolicy do
  @moduledoc """
  Merge strategy policy layer (CX-csmr).

  Wrapper above `Commonplace.Store.Merger.merge/4` that picks a strategy
  from configurable policy rather than forcing every caller to specify
  one. `Merger` remains the mechanism; this module is the decision.

  ## Resolution order

  1. **Explicit** — `opts[:strategy]` wins unconditionally. Reason:
     `:explicit`. Keep the override so callers who know better (tests,
     CLI with `--strategy`, programmatic callers with context) can
     bypass policy.
  2. **Doc-type config** — `opts[:doc_type]` is looked up in
     `Application.get_env(:commonplace, :merge_policy_by_doc_type, %{})`.
     If a strategy is mapped for that type, use it. Reason:
     `:doc_type_config`. Presence docs typically map to
     `:merge_snapshot` (frequent churn; epoch reset is cheap), while
     authoritative docs stay on `:translate` (namespace continuity
     matters).
  3. **State-vector threshold** — if L's namespace carries ≥ threshold
     distinct client IDs, use `:merge_snapshot` to reset the epoch.
     Threshold defaults to
     `Application.get_env(:commonplace, :merge_snapshot_sv_threshold,
     1000)` and is overridable per-call via `opts[:sv_threshold]`.
     Reason: `:sv_threshold`. The anchor is deliberately L (not R):
     `:translate` produces a commit in L's namespace, so L's SV is
     what we're preventing from bloating. Adding an R check here
     would be "improving" in the wrong direction.
  4. **Default** — `:translate`. Reason: `:default`.

  Every invocation emits
  `[:commonplace, :merge, :strategy_selected]` with metadata
  `%{strategy, reason, l, r}` before delegating. Observers can switch
  on `reason` to bucket dashboards (how often does the threshold fire
  vs. explicit overrides vs. doc-type config?).

  Underlying `Merger.merge/4` still emits its own `:completed` /
  `:failed` events — `:strategy_selected` is additive, not a
  replacement.
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
