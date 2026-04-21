defmodule Commonplace.SnapshotTrigger do
  @moduledoc """
  Mandatory-threshold snapshot trigger primitive (CX-4e2g).

  `maybe_snapshot/3` reads the chain length from `doc_uuid`'s current
  `:latest` back to the most recent `:snapshot` (or `:genesis`) and,
  if that length crosses a configured threshold, cuts a new snapshot
  via the CAS write primitive `CommitStore.write_snapshot_cas/5`.
  Below the threshold — no-op.

  Designed as the shared primitive that the producer-side hook
  (CX-tvyb), the sync-agent heartbeat sweep (CX-fab5), the
  reader-side lazy path (CX-fkvc), and the explicit CLI command
  (CX-2ok0) will all sit on top of.

  ## Concurrency

  Safe to call concurrently from multiple hook sites. Two properties
  together give "exactly one new snapshot per trigger cohort":

  1. Deterministic-anyone snapshotting (CX-umz): callers that observe
     the same parent build the same update bytes and the same
     derivation map, so the content-addressed commit id matches.
  2. The CAS write in `CommitStore.write_snapshot_cas/5` only commits
     if `:latest` still matches the expected parent. Callers who
     observed an older parent get `{:error, :parent_moved}`, which
     this module maps to the `:below_threshold` no-op reply.

  Callers who read `:latest` *after* the first snapshot landed see
  `chain_length = 0` (the walk stops at the snapshot) and no-op
  without even attempting a CAS.

  ## Configuration

  The `:chain_length_threshold` opt overrides everything. When omitted,
  the value falls back to `Application.get_env(:commonplace,
  :snapshot_chain_threshold, @default_chain_length_threshold)`.
  """

  alias Commonplace.Store.{CommitStore, Snapshotter}

  @default_chain_length_threshold 100

  @type maybe_snapshot_result ::
          {:ok, :snapshotted, Commonplace.Store.Commit.t()}
          | {:ok, :below_threshold, {:chain_length, non_neg_integer(), pos_integer()}}

  @doc """
  Check whether `doc_uuid` has crossed the configured snapshot
  threshold and, if so, cut a snapshot.

  Opts:
    - `:chain_length_threshold` — positive integer. When the number of
      regular commits stacked on top of the most recent snapshot
      reaches or exceeds this value, a snapshot is cut (mandatory).
    - `:soft_chain_length_threshold` (CX-592q) — positive integer, must
      be less than `:chain_length_threshold`. Heuristic layer: when
      chain length is at or above the soft threshold AND the most
      recent commit is older than `:lull_window_ms`, cut a snapshot.
      Inert unless `:lull_window_ms` is also set.
    - `:lull_window_ms` (CX-592q) — non-negative integer. Gates the
      soft-threshold firing. Inert unless `:soft_chain_length_threshold`
      is also set.
    - `:now` (CX-592q) — override for the current millisecond timestamp
      compared against the latest commit's timestamp. Defaults to
      `System.system_time(:millisecond)`. Tests inject a fixed value
      for determinism.

  Returns:
    - `{:ok, :snapshotted, commit}` when a new snapshot was written.
    - `{:ok, :below_threshold, {:chain_length, current, threshold}}`
      when no snapshot was cut (either below the threshold, still in a
      burst for the heuristic path, or a concurrent caller already
      landed one).
  """
  @spec maybe_snapshot(GenServer.server(), String.t(), keyword()) :: maybe_snapshot_result()
  def maybe_snapshot(store \\ CommitStore, doc_uuid, opts \\ []) do
    threshold = resolve_threshold(opts)

    case CommitStore.latest_commit(store, doc_uuid) do
      :none ->
        {:ok, :below_threshold, {:chain_length, 0, threshold}}

      {:ok, latest} ->
        chain_length = chain_length_since_snapshot(store, latest, 0)

        cond do
          chain_length == 0 ->
            {:ok, :below_threshold, {:chain_length, chain_length, threshold}}

          chain_length >= threshold ->
            attempt_snapshot(store, doc_uuid, latest, threshold)

          heuristic_should_fire?(latest, chain_length, opts) ->
            attempt_snapshot(store, doc_uuid, latest, threshold)

          true ->
            {:ok, :below_threshold, {:chain_length, chain_length, threshold}}
        end
    end
  end

  # CX-592q: lull-aware heuristic. Both `:soft_chain_length_threshold`
  # and `:lull_window_ms` must be set; either missing disables the
  # layer entirely. A "lull" is defined as the wall-clock gap between
  # `:now` and the latest commit's timestamp being >= `:lull_window_ms`.
  defp heuristic_should_fire?(latest, chain_length, opts) do
    soft = Keyword.get(opts, :soft_chain_length_threshold)
    window = Keyword.get(opts, :lull_window_ms)

    case {soft, window} do
      {soft, window} when is_integer(soft) and is_integer(window) ->
        now = Keyword.get(opts, :now, System.system_time(:millisecond))
        latest_ms = DateTime.to_unix(latest.timestamp, :millisecond)
        chain_length >= soft and now - latest_ms >= window

      _ ->
        false
    end
  end

  defp attempt_snapshot(store, doc_uuid, parent_commit, threshold) do
    {update_bytes, metadata} = Snapshotter.build_snapshot(store, doc_uuid, parent_commit)

    case CommitStore.write_snapshot_cas(
           store,
           doc_uuid,
           update_bytes,
           metadata,
           parent_commit.id
         ) do
      {:ok, commit} ->
        {:ok, :snapshotted, commit}

      {:error, :parent_moved} ->
        # Another hook beat us to it — equivalent to "already snapshotted,
        # chain_length now 0". Return the below-threshold reply so callers
        # don't need to distinguish the two no-op reasons.
        {:ok, :below_threshold, {:chain_length, 0, threshold}}
    end
  end

  defp resolve_threshold(opts) do
    Keyword.get(
      opts,
      :chain_length_threshold,
      Application.get_env(
        :commonplace,
        :snapshot_chain_threshold,
        @default_chain_length_threshold
      )
    )
  end

  # Walk parent chain from `commit` counting regular commits; stop at
  # (and exclude) the first :snapshot or :genesis commit. Genesis is
  # treated as an implicit snapshot boundary — the namespace root the
  # rest of the chain descends from.
  defp chain_length_since_snapshot(_store, %{metadata: %{kind: :snapshot}}, count), do: count
  defp chain_length_since_snapshot(_store, %{metadata: %{kind: :genesis}}, count), do: count

  defp chain_length_since_snapshot(store, commit, count) do
    case commit.parent_id do
      nil ->
        count + 1

      parent_id ->
        case CommitStore.get_commit(store, parent_id) do
          {:ok, parent} -> chain_length_since_snapshot(store, parent, count + 1)
          :none -> count + 1
        end
    end
  end
end
