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

  ## Two entry points, one logic

  `run/2` is the GenServer-mediated path (the host-gated task). `run_on_db/2`
  is the same selection/walk/report over a raw CubDB handle, for the ONE
  caller that legitimately works below the GenServer: the boot rebuild
  (`rebuild_doc_commit_index`), which re-derives the whole index from
  struct fields and must ALSO reproduce chain-derived membership — else
  any future rebuild silently erases what the backfill wrote and
  manufactures the doctrine violation back (plan #14426: the repair path
  was the vulnerability).
  """

  alias Commonplace.Store.CommitStore
  require Logger

  # The same range bound the store's own scans use (CX-mg8s: a shorter
  # bound silently drops high keys).
  @max_key_binary :binary.copy(<<255>>, 64)

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
      ^ready -> do_run(server_access(store), budget)
      other -> {:error, {:doc_commit_index_not_ready, other}}
    end
  end

  @doc """
  The rebuild's entry point: same selection, walk, all-or-nothing writes
  and report as `run/2`, over a raw CubDB handle. NO readiness check —
  the boot rebuild is the exclusive owner of the not-ready window and
  calls this after its struct-field pass, before flipping the state key.
  Nobody else may call this: every other writer goes through the
  GenServer verb, which refuses a non-ready index.
  """
  @spec run_on_db(GenServer.server() | pid(), keyword()) :: {:ok, report()}
  def run_on_db(db, opts \\ []) do
    budget = Keyword.get(opts, :walk_budget, CommitStore.max_commit_log_limit())
    do_run(db_access(db), budget)
  end

  # The store-access seam: run/2 reads and writes through the CommitStore
  # API (the write via the ready-gated choke verb); run_on_db/2 reads and
  # writes the raw db with the SAME semantics ({:ok, nil} for a head
  # pointer at a missing commit row, the CX-mg8s-safe range bound).
  defp server_access(store) do
    %{
      all_docs: fn -> store |> CommitStore.all_doc_uuids() |> MapSet.to_list() |> Enum.sort() end,
      latest: fn doc -> CommitStore.latest_commit(store, doc) end,
      member?: fn doc, id -> CommitStore.doc_has_commit?(store, doc, id) end,
      page: fn from_id, limit -> CommitStore.commit_log_from(store, from_id, limit: limit) end,
      put_rows: fn doc, ids ->
        CommitStore.put_backfilled_doc_commit_index_rows(store, doc, ids)
      end
    }
  end

  defp db_access(db) do
    %{
      all_docs: fn ->
        CubDB.select(db, min_key: {:latest, ""}, max_key: {:latest, @max_key_binary})
        |> Enum.map(fn {{:latest, uuid}, _commit_id} -> uuid end)
        |> Enum.sort()
      end,
      latest: fn doc ->
        case CubDB.get(db, {:latest, doc}) do
          nil -> :none
          commit_id -> {:ok, CubDB.get(db, {:commit, commit_id})}
        end
      end,
      member?: fn doc, id -> CubDB.get(db, {:doc_commit, doc, id}) == true end,
      # A plain parent_id chase by point reads — the walk only needs ids,
      # the last element's parent_id, and emptiness-on-missing-row, which
      # this shares with commit_log_from.
      page: fn from_id, limit ->
        Stream.unfold({from_id, limit}, fn
          {nil, _left} ->
            nil

          {_id, 0} ->
            nil

          {id, left} ->
            case CubDB.get(db, {:commit, id}) do
              nil -> nil
              commit -> {commit, {commit.parent_id, left - 1}}
            end
        end)
        |> Enum.to_list()
      end,
      put_rows: fn doc, ids ->
        CubDB.put_multi(db, Enum.map(ids, fn id -> {{:doc_commit, doc, id}, true} end))
        :ok
      end
    }
  end

  defp do_run(access, budget) do
    all_docs = access.all_docs.()

    # Both predicates computed in one pass over the SAME heads, so the
    # cross-check cannot diverge by reading the store twice. Selection
    # carries the head struct so the processing loop never re-reads it.
    # `{:ok, nil}` is a `:latest` pointer naming a commit with no
    # `{:commit}` row at all — named at selection time, never walked.
    {selected, struct_f2, head_missing} =
      Enum.reduce(all_docs, {[], [], []}, fn doc, {sel, f2, missing} ->
        case access.latest.(doc) do
          :none ->
            {sel, f2, missing}

          {:ok, nil} ->
            {sel, f2, [doc | missing]}

          {:ok, head} ->
            f2 = if head.doc_uuid != doc, do: [doc | f2], else: f2

            sel =
              if access.member?.(doc, head.id),
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
        case backfill_doc(access, doc, head.id, budget) do
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

    summary =
      "DocCommitBackfill complete: total=#{report.total_docs} " <>
        "selected=#{length(report.selected)} struct_f2=#{length(report.struct_f2)} " <>
        "backfilled=#{length(report.backfilled)} capped=#{length(report.capped)} " <>
        "head_commit_missing=#{length(report.head_commit_missing)} " <>
        "rows_written=#{report.rows_written} " <>
        "rows_already_present=#{report.rows_already_present} " <>
        "walk_budget=#{report.walk_budget}"

    # This also runs on every index rebuild (any store boot with a
    # non-ready state) — the nothing-selected case stays quiet; anything
    # capped or head-missing is a WARNING, not an info line (a doc left
    # dangling by a bounded walk must not scroll past as routine).
    cond do
      report.capped != [] or report.head_commit_missing != [] -> Logger.warning(summary)
      report.selected != [] -> Logger.info(summary)
      true -> Logger.debug(summary)
    end

    {:ok, report}
  end

  # Walk the whole chain first; write only on a COMPLETE walk. The walk is
  # deliberately doc-agnostic (a pure parent_id walk, exactly like
  # commit_log_from itself) — fork-lineage chains cross `.doc_uuid`
  # boundaries and every commit reached belongs to this doc's history by
  # the walk itself, which is the definition being made true.
  defp backfill_doc(access, doc, head_id, budget) do
    case walk_chain(access, head_id, [], 0, budget) do
      {:complete, ids} ->
        {present, missing} = Enum.split_with(ids, &access.member?.(doc, &1))

        :ok = access.put_rows.(doc, missing)

        {:backfilled, %{rows_written: length(missing), rows_already_present: length(present)}}

      {:capped, walked} ->
        {:capped, %{walked: walked, budget: budget}}

      :head_commit_missing ->
        {:head_commit_missing, head_id}
    end
  end

  defp walk_chain(_access, _from_id, _ids, walked, budget) when walked >= budget,
    do: {:capped, walked}

  defp walk_chain(access, from_id, ids, walked, budget) do
    page = access.page.(from_id, min(@walk_page, budget - walked))

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
            walk_chain(access, parent_id, ids, walked + length(page), budget)
        end
    end
  end
end
