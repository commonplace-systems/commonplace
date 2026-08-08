defmodule Commonplace.SnapshotCompact do
  @moduledoc """
  Three-pass accounting for the deliberate head-snapshot sweep.

  This module adds no snapshot policy. It measures the same post-trim
  chain used by `Commonplace.Tree.DocBuilder`, takes the existing
  `:reader_lazy_snapshot_threshold`, and executes through
  `Commonplace.SnapshotWorker` — the exact single-flight signer/CAS path
  used by lazy reads. The final verdict is a fresh destination census,
  never the execution tally.
  """

  alias Commonplace.SnapshotWorker
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder

  @type mode :: :dry_run | :execute

  @doc "Run a dry census or the complete census/execute/acceptance sequence."
  @spec run(mode(), GenServer.server(), keyword()) :: map()
  def run(mode, store \\ CommitStore, opts \\ []) when mode in [:dry_run, :execute] do
    threshold =
      Keyword.get(
        opts,
        :threshold,
        Application.get_env(:commonplace, :reader_lazy_snapshot_threshold, 100)
      )

    census = census(store, threshold)

    case mode do
      :dry_run ->
        %{mode: mode, threshold: threshold, census: census, ok?: census.identity_ok?}

      :execute ->
        execute_and_accept(store, threshold, census)
    end
  end

  @doc "Destination census with an explicit work/noop/unreadable identity."
  @spec census(GenServer.server(), pos_integer()) :: map()
  def census(store \\ CommitStore, threshold) when is_integer(threshold) and threshold > 0 do
    uuids = store |> CommitStoreClient.all_doc_uuids() |> Enum.sort()

    {work, noop, unreadable} =
      Enum.reduce(uuids, {[], [], []}, fn uuid, {work, noop, unreadable} ->
        case inspect_doc(store, uuid) do
          # The read path's post-trim count includes the snapshot commit
          # itself. Sweeping only counts strictly-over-threshold shapes, so
          # acceptance can state the invariant directly as length <= limit.
          # At threshold + 1 the trigger sees at least `threshold` deltas and
          # therefore uses the same mandatory boundary as the lazy path.
          {:ok, shape} when shape.chain_length > threshold ->
            {[shape | work], noop, unreadable}

          {:ok, shape} ->
            {work, [shape | noop], unreadable}

          {:error, reason} ->
            {work, noop, [%{uuid: uuid, reason: reason} | unreadable]}
        end
      end)

    work = sort_shapes(work)
    noop = sort_shapes(noop)
    unreadable = Enum.sort_by(unreadable, & &1.uuid)
    total = length(uuids)
    accounted = length(work) + length(noop) + length(unreadable)

    %{
      total: total,
      work: work,
      noop: noop,
      unreadable: unreadable,
      snapshot_bounded_noop: Enum.filter(noop, & &1.snapshot_bounded?),
      distribution: distribution(work ++ noop),
      worst: Enum.take(sort_shapes(work ++ noop), 10),
      accounted: accounted,
      identity_ok?: accounted == total
    }
  end

  @doc "Human-readable operator report used by `bin/snapshot-compact`."
  @spec format(map()) :: String.t()
  def format(report) do
    census = report.census

    lines = [
      "snapshot-compact: mode=#{report.mode} threshold=#{report.threshold}",
      "census: total=#{census.total} work=#{length(census.work)} noop=#{length(census.noop)} unreadable=#{length(census.unreadable)}",
      "snapshot-bounded noop (#{length(census.snapshot_bounded_noop)}): #{format_uuid_set(census.snapshot_bounded_noop)}",
      "census identity: work + noop + unreadable = total :: #{length(census.work)} + #{length(census.noop)} + #{length(census.unreadable)} = #{census.total} [#{verdict(census.identity_ok?)}]",
      "distribution: #{inspect(census.distribution)}",
      "worst 10:",
      Enum.map_join(census.worst, "\n", &format_shape/1),
      format_named("unreadable", census.unreadable)
    ]

    lines =
      case report.mode do
        :dry_run ->
          lines ++ ["dry-run: no snapshot requests sent"]

        :execute ->
          execution = report.execution
          acceptance = report.acceptance

          lines ++
            [
              "execution outcomes:",
              Enum.map_join(execution.outcomes, "\n", &format_outcome/1),
              "execution identity: snapshotted + already_bounded + refused = work :: #{execution.snapshotted} + #{execution.already_bounded} + #{execution.refused} = #{length(census.work)} [#{verdict(execution.identity_ok?)}]",
              "acceptance: total=#{acceptance.total} bounded=#{acceptance.bounded} named_refusals=#{length(acceptance.named_refusals)} unaccounted=#{length(acceptance.unaccounted)}",
              "acceptance denominator stable: census_total=#{census.total} destination_total=#{acceptance.total} [#{verdict(acceptance.denominator_stable?)}]",
              format_named("named refusals", acceptance.named_refusals),
              format_named("unaccounted", acceptance.unaccounted),
              "acceptance identity: bounded + named_refusals + unaccounted = total :: #{acceptance.bounded} + #{length(acceptance.named_refusals)} + #{length(acceptance.unaccounted)} = #{acceptance.total} [#{verdict(acceptance.identity_ok?)}]",
              "destination verdict: #{verdict(report.ok?)}"
            ]
      end

    (lines |> Enum.reject(&(&1 == "")) |> Enum.join("\n")) <> "\n"
  end

  defp execute_and_accept(store, threshold, census) do
    outcomes = Enum.map(census.work, &execute_one(store, &1.uuid, threshold))

    execution = %{
      outcomes: outcomes,
      snapshotted: Enum.count(outcomes, &(&1.status == :snapshotted)),
      already_bounded: Enum.count(outcomes, &(&1.status == :already_bounded)),
      refused: Enum.count(outcomes, &(&1.status == :refused))
    }

    execution =
      Map.put(
        execution,
        :identity_ok?,
        execution.snapshotted + execution.already_bounded + execution.refused ==
          length(census.work)
      )

    acceptance_census = census(store, threshold)

    refusal_reasons =
      census.unreadable
      |> Enum.map(&{&1.uuid, {:unreadable, &1.reason}})
      |> Map.new()
      |> Map.merge(
        outcomes
        |> Enum.filter(&(&1.status == :refused))
        |> Map.new(&{&1.uuid, &1.reason})
      )
      |> Map.merge(Map.new(acceptance_census.unreadable, &{&1.uuid, {:unreadable, &1.reason}}))

    remaining = acceptance_census.work ++ acceptance_census.unreadable

    {named_refusals, unaccounted} =
      Enum.split_with(remaining, &Map.has_key?(refusal_reasons, &1.uuid))

    named_refusals =
      Enum.map(named_refusals, fn item ->
        %{uuid: item.uuid, reason: Map.fetch!(refusal_reasons, item.uuid)}
      end)

    acceptance = %{
      total: acceptance_census.total,
      bounded: length(acceptance_census.noop),
      named_refusals: named_refusals,
      unaccounted: unaccounted,
      denominator_stable?: acceptance_census.total == census.total
    }

    acceptance =
      Map.put(
        acceptance,
        :identity_ok?,
        acceptance.bounded + length(named_refusals) + length(unaccounted) == acceptance.total and
          acceptance.denominator_stable?
      )

    %{
      mode: :execute,
      threshold: threshold,
      census: census,
      execution: execution,
      acceptance_census: acceptance_census,
      acceptance: acceptance,
      ok?:
        census.identity_ok? and execution.identity_ok? and acceptance.identity_ok? and
          unaccounted == []
    }
  end

  defp execute_one(store, uuid, threshold) do
    result =
      SnapshotWorker.request_and_wait(
        SnapshotWorker,
        store,
        uuid,
        [chain_length_threshold: threshold],
        :infinity
      )

    case result do
      {:ok, :snapshotted, commit} ->
        %{
          uuid: uuid,
          status: :snapshotted,
          commit_id: Base.encode16(commit.id, case: :lower),
          signer_id: commit.signer_id,
          kind: commit.metadata.kind
        }

      {:ok, :below_threshold, detail} ->
        %{uuid: uuid, status: :already_bounded, detail: detail}

      {:ok, :skipped, detail} ->
        %{uuid: uuid, status: :refused, reason: detail}

      other ->
        %{uuid: uuid, status: :refused, reason: {:snapshot_worker, other}}
    end
  end

  defp inspect_doc(store, uuid) do
    with {:ok, _doc} <- reconstruct(store, uuid) do
      commits =
        store
        |> CommitStoreClient.commit_log(uuid, limit: CommitStore.max_commit_log_limit())
        |> Enum.reverse()

      trimmed = trim_to_latest_snapshot(commits)
      chain_length = Enum.count(trimmed, &(commit_kind(&1) != :genesis))
      snapshot_bounded? = Enum.any?(trimmed, &(commit_kind(&1) == :snapshot))
      head_kind = commits |> List.last() |> commit_kind()

      {:ok,
       %{
         uuid: uuid,
         chain_length: chain_length,
         snapshot_bounded?: snapshot_bounded?,
         head_kind: head_kind
       }}
    else
      other -> {:error, normalize_error(other)}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, inspect(reason)}}
  end

  defp reconstruct(store, uuid) do
    # `mint: false` is the long-deployed no-write spelling. Do not make this
    # operator path depend on the separately parked `read_only:` work.
    case DocBuilder.reconstruct_doc(store, uuid, mint: false) do
      {:ok, _doc} = ok -> ok
      :none -> {:error, :no_commits}
      other -> {:error, other}
    end
  end

  defp trim_to_latest_snapshot(commits) do
    case Enum.find_index(Enum.reverse(commits), &(commit_kind(&1) == :snapshot)) do
      nil -> commits
      idx_from_end -> Enum.drop(commits, length(commits) - 1 - idx_from_end)
    end
  end

  defp commit_kind(nil), do: :none
  defp commit_kind(%{metadata: %{kind: kind}}), do: kind
  defp commit_kind(_commit), do: :unknown

  defp normalize_error({:error, reason}), do: reason
  defp normalize_error(other), do: other

  defp sort_shapes(shapes), do: Enum.sort_by(shapes, &{-&1.chain_length, &1.uuid})

  defp distribution(shapes) do
    shapes
    |> Enum.frequencies_by(& &1.chain_length)
    |> Enum.sort()
  end

  defp verdict(true), do: "OK"
  defp verdict(false), do: "BROKEN"

  defp format_shape(shape) do
    "  #{shape.uuid} chain=#{shape.chain_length} head=#{shape.head_kind} snapshot_bounded=#{shape.snapshot_bounded?}"
  end

  defp format_outcome(outcome) do
    "  #{outcome.uuid} #{outcome.status} #{inspect(Map.drop(outcome, [:uuid, :status]))}"
  end

  defp format_uuid_set([]), do: "(none)"
  defp format_uuid_set(entries), do: Enum.map_join(entries, ", ", & &1.uuid)

  defp format_named(_label, []), do: ""

  defp format_named(label, entries) do
    label <>
      ":\n" <>
      Enum.map_join(entries, "\n", fn entry ->
        detail = Map.get(entry, :reason, Map.drop(entry, [:uuid]))
        "  #{entry.uuid} #{inspect(detail)}"
      end)
  end
end
