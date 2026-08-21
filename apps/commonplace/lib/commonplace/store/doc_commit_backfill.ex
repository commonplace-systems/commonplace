defmodule Commonplace.Store.DocCommitBackfill do
  @moduledoc """
  The fork-lineage `{:doc_commit}` backfill — the "(a) round" ratified in
  `docs/plans/2026-08-21-doc-commit-backfill-brief.md`.

  The defect it repairs (F2, measured 2026-08-21): 116 docs carry a
  `:latest` pointing at commits with zero `{:doc_commit, <key_doc>, _}`
  rows — the old fork copied the head pointer while every membership row
  stayed with the ancestor doc. The chains READ fine (`parent_id` walks
  are doc-agnostic), but every fact-keyed consumer — `Projection`'s
  cross-check, the [4] chit-ancestry mint gate, World-B's doctrine that
  ownership IS the `{:doc_commit}` key — refuses them.

  ## Selection is the membership FACT gap, re-derived at run time

  A doc is selected iff it has a `:latest` AND that head commit is not a
  `doc_has_commit?/3` member of the doc — the exact fact the fact-keyed
  `fetch_commit` switch reads, never a stored list. Today this population
  coincides byte-exactly with the F2 struct-mismatch set (0/116 members,
  116/116 zero own rows = World-B's `dangling_latest`); the run
  cross-checks that coincidence and NAMES any doc where the two
  predicates disagree rather than assuming it.

  ## Per-doc all-or-nothing, which is also the resume story

  Each selected doc's chain is walked backward from `:latest` in bounded
  pages (`commit_log_from/3`, the ChitAncestry paging shape). A complete
  walk (genesis reached) writes ALL the doc's missing rows in one atomic
  `put_backfilled_doc_commit_index_rows/3` call; a walk that exhausts its
  budget writes NOTHING and reports the doc as a NAMED `capped` outcome —
  never a silent partial. Because writes are per-doc atomic and selection
  is the fact gap, a killed run needs no cursor: repaired docs drop out
  of the next run's selection by their own head row.

  ## What this never touches

  `{:doc_commit_index, :state}` (readiness is the boot rebuild's,
  exclusively — the write verb refuses on a non-ready index), `:latest`
  pointers, commit content, signatures. This writes index rows, only.

  ## Run model

  The BUILD-1 §3 precedent verbatim: not run in the live serve. The
  launch opens the STOPPED serve's data_dir as sole flock holder under a
  verified systemd ceiling — see `mix commonplace.backfill_doc_commit_index`.
  """

  alias Commonplace.Store.CommitStore
  require Logger

  # Same paging shape as ChitAncestry's descent walk: small pages so a
  # short chain never pays for the whole budget's worth of rows.
  @walk_page 256

  @type doc_outcome ::
          {:backfilled,
           %{rows_written: non_neg_integer(), rows_already_present: non_neg_integer()}}
          | {:capped, %{walked: non_neg_integer(), budget: non_neg_integer()}}
          | {:head_commit_missing, binary()}

  @type report :: %{
          total_docs: non_neg_integer(),
          selected: [String.t()],
          struct_f2: [String.t()],
          selection_vs_struct_f2_diff: %{
            selected_only: [String.t()],
            struct_f2_only: [String.t()]
          },
          backfilled: [String.t()],
          capped: [%{doc: String.t(), walked: non_neg_integer(), budget: non_neg_integer()}],
          head_commit_missing: [String.t()],
          rows_written: non_neg_integer(),
          rows_already_present: non_neg_integer(),
          walk_budget: non_neg_integer()
        }

  @doc """
  Run the backfill. Idempotent — a repaired doc is not selected again,
  and a re-run over an already-repaired corpus reports
  `selected: []`/`rows_written: 0`. Returns the full report; `backfilled`
  is the processed ID SET the World-B set-difference convergence check
  compares against (acceptance 5 — never a count-delta).

  Options:
    * `:walk_budget` — max commits walked per doc (default
      `CommitStore.max_commit_log_limit/0`). A doc whose chain exceeds it
      is `capped`, with zero rows written.
  """
  @spec run(GenServer.server(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(store \\ CommitStore, opts \\ []) do
    budget = Keyword.get(opts, :walk_budget, CommitStore.max_commit_log_limit())

    # Exact-match the canonical ready value; ANY other state — nil,
    # {:rebuilding, ...}, an unexpected shape — refuses. Fail-closed: a
    # state this code cannot classify is not a state it may write into.
    ready = CommitStore.doc_commit_index_ready()

    case CommitStore.doc_commit_index_state(store) do
      ^ready -> do_run(store, budget)
      other -> {:error, {:doc_commit_index_not_ready, other}}
    end
  end

  defp do_run(store, budget) do
    all_docs = store |> CommitStore.all_doc_uuids() |> MapSet.to_list() |> Enum.sort()

    # Both predicates computed in one pass over the SAME heads, so the
    # cross-check cannot diverge by reading the store twice. Selection
    # carries the head struct so the processing loop never re-reads it.
    # `{:ok, nil}` is a `:latest` pointer naming a commit with no
    # `{:commit}` row at all — named at selection time, never walked.
    {selected, struct_f2, head_missing} =
      Enum.reduce(all_docs, {[], [], []}, fn doc, {sel, f2, missing} ->
        case CommitStore.latest_commit(store, doc) do
          :none ->
            {sel, f2, missing}

          {:ok, nil} ->
            {sel, f2, [doc | missing]}

          {:ok, head} ->
            f2 = if head.doc_uuid != doc, do: [doc | f2], else: f2

            sel =
              if CommitStore.doc_has_commit?(store, doc, head.id),
                do: sel,
                else: [{doc, head} | sel]

            {sel, f2, missing}
        end
      end)

    selected = Enum.reverse(selected)
    selected_docs = Enum.map(selected, fn {doc, _head} -> doc end)
    struct_f2 = Enum.reverse(struct_f2)

    acc0 = %{
      backfilled: [],
      capped: [],
      head_commit_missing: head_missing,
      rows_written: 0,
      rows_already_present: 0
    }

    acc =
      Enum.reduce(selected, acc0, fn {doc, head}, acc ->
        case backfill_doc(store, doc, head.id, budget) do
          {:backfilled, %{rows_written: written, rows_already_present: present}} ->
            %{
              acc
              | backfilled: [doc | acc.backfilled],
                rows_written: acc.rows_written + written,
                rows_already_present: acc.rows_already_present + present
            }

          {:capped, %{walked: walked, budget: budget}} ->
            %{acc | capped: [%{doc: doc, walked: walked, budget: budget} | acc.capped]}

          {:head_commit_missing, _head_id} ->
            %{acc | head_commit_missing: [doc | acc.head_commit_missing]}
        end
      end)

    sel_set = MapSet.new(selected_docs)
    f2_set = MapSet.new(struct_f2)

    report = %{
      total_docs: length(all_docs),
      selected: selected_docs,
      struct_f2: struct_f2,
      selection_vs_struct_f2_diff: %{
        selected_only: sel_set |> MapSet.difference(f2_set) |> Enum.sort(),
        struct_f2_only: f2_set |> MapSet.difference(sel_set) |> Enum.sort()
      },
      backfilled: Enum.reverse(acc.backfilled),
      capped: Enum.reverse(acc.capped),
      head_commit_missing: Enum.reverse(acc.head_commit_missing),
      rows_written: acc.rows_written,
      rows_already_present: acc.rows_already_present,
      walk_budget: budget
    }

    Logger.info(
      "DocCommitBackfill complete: total=#{report.total_docs} " <>
        "selected=#{length(report.selected)} struct_f2=#{length(report.struct_f2)} " <>
        "backfilled=#{length(report.backfilled)} capped=#{length(report.capped)} " <>
        "head_commit_missing=#{length(report.head_commit_missing)} " <>
        "rows_written=#{report.rows_written} " <>
        "rows_already_present=#{report.rows_already_present} " <>
        "walk_budget=#{report.walk_budget}"
    )

    {:ok, report}
  end

  # Walk the whole chain first; write only on a COMPLETE walk. The walk is
  # deliberately doc-agnostic (a pure parent_id walk, exactly like
  # commit_log_from itself) — fork-lineage chains cross `.doc_uuid`
  # boundaries and every commit reached belongs to this doc's history by
  # the walk itself, which is the definition being made true.
  defp backfill_doc(store, doc, head_id, budget) do
    case walk_chain(store, head_id, [], 0, budget) do
      {:complete, ids} ->
        {present, missing} =
          Enum.split_with(ids, &CommitStore.doc_has_commit?(store, doc, &1))

        :ok = CommitStore.put_backfilled_doc_commit_index_rows(store, doc, missing)

        {:backfilled, %{rows_written: length(missing), rows_already_present: length(present)}}

      {:capped, walked} ->
        {:capped, %{walked: walked, budget: budget}}

      :head_commit_missing ->
        {:head_commit_missing, head_id}
    end
  end

  defp walk_chain(_store, _from_id, _ids, walked, budget) when walked >= budget,
    do: {:capped, walked}

  defp walk_chain(store, from_id, ids, walked, budget) do
    page = CommitStore.commit_log_from(store, from_id, limit: min(@walk_page, budget - walked))

    case {page, ids} do
      {[], []} ->
        # First fetch returned nothing: the head pointer names a commit
        # with no {:commit} row at all — not this round's defect, NAMED.
        :head_commit_missing

      {[], _} ->
        # Mid-walk empty page: parent_id named a missing commit. The chain
        # is unwalkably absent past this point — same named outcome.
        :head_commit_missing

      {page, ids} ->
        ids = Enum.reduce(page, ids, fn c, acc -> [c.id | acc] end)

        case List.last(page) do
          %{parent_id: nil} ->
            {:complete, Enum.reverse(ids)}

          %{parent_id: parent_id} ->
            walk_chain(store, parent_id, ids, walked + length(page), budget)
        end
    end
  end
end
