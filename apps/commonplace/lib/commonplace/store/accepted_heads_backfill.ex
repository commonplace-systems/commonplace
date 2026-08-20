defmodule Commonplace.Store.AcceptedHeadsBackfill do
  @moduledoc """
  BUILD-1 §3: one-time backfill of the accepted-head index for documents
  written before the 2a head-update seam existed (legacy docs the seam
  never maintained).

  For each document it DERIVES the frontier via `AcceptedHeads.of/2` (the
  scan-based oracle), VERIFIES that frontier is an antichain via
  `CommitInvariants.antichain_of/3` (the raised acceptance from plan
  #13407 — this backfill is the SOLE corpus-wide antichain guard until the
  World-B standing audit exists), and writes it through the
  choke-sanctioned full-set path (`CommitStore.put_backfilled_accepted_heads/3`).

  ## Chunked + resumable (host-safety ② and ③)

  Docs are processed in chunks; each chunk's index rows land ATOMICALLY
  with the resume cursor (`{:rebuilding, last_doc}`), and only a complete
  pass writes `{:ready, v}`. A kill (e.g. a MemoryMax stop) leaves
  `{:rebuilding, cursor}`, so a re-run resumes past the cursor and a
  half-run never presents as `:ready` — resumability and the
  not-half-verified guarantee are the same mechanism. §4 removes
  SiblingMerger's scan-fallback only when the state reads `{:ready, v}`.

  ## Observed-max (⑦ — reported OUT of the run, not just bounded)

  `working_set_max` is the largest per-doc commit set the derive touched
  (`|all_commit_ids_for_doc(doc)|`) — the memory-relevant peak. A first run
  under a known-worst-so-far MemoryMax reports this so run 2's ceiling is
  evidence rather than a guess. It is in the returned report AND logged; a
  run that reports no maximum has produced nothing.

  ## Run model (b)

  Not run in the live serve. The RUN launches its own `CommitStore` against
  the STOPPED serve's data_dir (sole opener) under `systemd-run --unit 6G`,
  per the ceremony in `/home/jes/boss-clod/INCREMENT-3-BRIEF.md`. This
  module is the logic; the ceremony (stop/verify-unit/restart) is boss's.
  """

  alias Commonplace.Store.{AcceptedHeads, CommitInvariants, CommitStore}
  require Logger

  @default_chunk 1_000

  @type report :: %{
          total_docs: non_neg_integer(),
          docs_seen: non_neg_integer(),
          docs_written: non_neg_integer(),
          skipped_no_commits: non_neg_integer(),
          working_set_max: non_neg_integer(),
          violations: [map()],
          resumed_from: String.t() | nil,
          terminal_state: term()
        }

  @doc """
  Backfill the accepted-head index. Idempotent (re-deriving a
  seam-maintained doc writes the same value) and resumable (continues past
  a recorded `{:rebuilding, cursor}`). Returns a stamped report.
  """
  @spec run(GenServer.server(), keyword()) :: report()
  def run(store \\ CommitStore, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk, @default_chunk)
    # The antichain verify. Default is the real check; a test may inject one
    # to exercise the violation-handling branch deterministically (the real
    # check only fires on of/2 regression or store corruption).
    verify_fn = Keyword.get(opts, :verify_fn, &CommitInvariants.antichain_of/3)
    all_docs = store |> CommitStore.all_doc_uuids() |> MapSet.to_list() |> Enum.sort()

    resumed_from =
      case CommitStore.accepted_head_backfill_state(store) do
        {:rebuilding, cursor} -> cursor
        _ -> nil
      end

    remaining =
      case resumed_from do
        nil -> all_docs
        cursor -> Enum.filter(all_docs, &(&1 > cursor))
      end

    acc0 = %{
      total_docs: length(all_docs),
      docs_seen: 0,
      docs_written: 0,
      skipped_no_commits: 0,
      working_set_max: 0,
      violations: [],
      resumed_from: resumed_from
    }

    report =
      remaining
      |> Enum.chunk_every(chunk_size)
      |> Enum.reduce(acc0, fn chunk, acc ->
        {rows, acc} = derive_chunk(store, chunk, verify_fn, acc)

        :ok =
          CommitStore.put_backfilled_accepted_heads(
            store,
            Enum.reverse(rows),
            {:rebuilding, List.last(chunk)}
          )

        acc
      end)
      |> Map.update!(:violations, &Enum.reverse/1)

    # ⛔ :ready ONLY when no doc failed the verify (commonplace-coder #13593):
    # a violating doc is recorded but NOT written, so its index row is
    # absent. If that terminal state were :ready, §4 would remove the
    # :latest-guard fallback and the doc's siblings would go silently
    # invisible. :ready must mean "complete AND every doc indexed", which
    # §4 reads it as; violations therefore yield a distinct non-:ready
    # terminal state that blocks §4 and flags the corruption.
    terminal_state =
      if report.violations == [] do
        CommitStore.accepted_head_index_ready()
      else
        {:completed_with_violations, length(report.violations)}
      end

    :ok = CommitStore.put_backfilled_accepted_heads(store, [], terminal_state)
    report = Map.put(report, :terminal_state, terminal_state)

    Logger.info(
      "AcceptedHeadsBackfill complete: " <>
        "total=#{report.total_docs} seen=#{report.docs_seen} written=#{report.docs_written} " <>
        "skipped_no_commits=#{report.skipped_no_commits} working_set_max=#{report.working_set_max} " <>
        "violations=#{length(report.violations)} terminal_state=#{inspect(terminal_state)} " <>
        "resumed_from=#{inspect(report.resumed_from)}"
    )

    report
  end

  # Derive + verify each doc in the chunk; accumulate {doc, set} rows to
  # write and the running metrics. A frontier that fails the antichain
  # check is a derivation bug or corrupt data: recorded, NOT written (never
  # persist a non-antichain).
  defp derive_chunk(store, chunk, verify_fn, acc) do
    Enum.reduce(chunk, {[], acc}, fn doc, {rows, acc} ->
      case AcceptedHeads.of(store, doc) do
        :none ->
          {rows,
           %{acc | docs_seen: acc.docs_seen + 1, skipped_no_commits: acc.skipped_no_commits + 1}}

        {:ok, set} ->
          working = MapSet.size(CommitStore.all_commit_ids_for_doc(store, doc))

          acc = %{
            acc
            | docs_seen: acc.docs_seen + 1,
              working_set_max: max(acc.working_set_max, working)
          }

          case verify_fn.(set, store, doc) do
            :ok ->
              {[{doc, set} | rows], %{acc | docs_written: acc.docs_written + 1}}

            {:violation, details} ->
              {rows, %{acc | violations: [details | acc.violations]}}
          end
      end
    end)
  end
end
