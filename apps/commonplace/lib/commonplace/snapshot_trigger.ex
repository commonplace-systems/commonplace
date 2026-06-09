defmodule Commonplace.SnapshotTrigger do
  @moduledoc """
  Mandatory-threshold snapshot trigger primitive (CX-4e2g).

  `maybe_snapshot/3` reads the chain length from `doc_uuid`'s current
  `:latest` back to the most recent `:snapshot` (or `:genesis`) commit
  and, if that length crosses a configured threshold, cuts a new
  snapshot via the compare-and-swap write primitive
  `CommitStore.write_snapshot_cas/5`. Below the threshold — no-op.

  A snapshot re-encodes the whole document into one self-contained
  commit, collapsing a long chain of incremental commits into a single
  read. Cutting them on a chain-length threshold is what bounds the
  worst-case cost of reconstructing a doc as it accumulates edits —
  this primitive is the policy that decides *when* that collapse
  happens.

  Designed as the shared primitive that the producer-side hook
  (CX-tvyb), the sync-agent heartbeat sweep (CX-fab5), the
  reader-side lazy path (CX-fkvc), and the explicit CLI command
  (CX-2ok0) will all sit on top of.

  ## When a snapshot fires

  After the debounce guard (below), two independent conditions can
  trigger a cut:

  1. **Mandatory hard threshold.** When the chain length since the last
     snapshot reaches `:chain_length_threshold`, a snapshot is cut
     unconditionally — the backstop that bounds worst-case
     reconstruction cost.
  2. **Soft-threshold lull heuristic (CX-592q).** Below the hard cap but
     at or above a smaller `:soft_chain_length_threshold`, *and* when no
     new commit has arrived for `:lull_window_ms` of wall-clock time (a
     lull), a snapshot is cut early. The intuition: a doc that has gone
     quiet partway up a chain is a cheap moment to checkpoint, rather
     than waiting to hit the hard cap during the next burst. Inert unless
     BOTH opts are set.

  Below every threshold — no-op.

  ## Debounce (CX-0nkq)

  A per-doc debounce window sits *in front* of the threshold check.
  `maybe_snapshot` is fired from several sites at once — most
  aggressively the reader-side lazy path
  (`DocBuilder.maybe_lazy_snapshot` via `Task.start`), which under read
  pressure can spawn many concurrent Tasks that all pile up at the
  `CommitStore` mailbox (a fork on a deep tree timed out at 5s under
  that contention). The debounce caps the doc to one snapshot *attempt*
  per `@debounce_window_ms` regardless of how many callers fire,
  returning `{:ok, :debounced, _}` for the suppressed ones. The window
  is backed by a public ETS table (`init_debounce_table/0`, created at
  application start) so any process can probe it without a GenServer
  round-trip. This is deliberately the smallest viable relief — the
  proper single-flight `SnapshotWorker` GenServer is still tracked on
  CX-0nkq.

  ## Concurrency

  The debounce above is a coarse first filter: it reduces how many
  callers even attempt a write, but it is best-effort, not a
  correctness boundary. Exactly-once is enforced *underneath* it — even
  if several callers slip through the same window, two properties
  together give "exactly one new snapshot per trigger cohort":

  1. Deterministic-anyone snapshotting (CX-umz): any two callers that
     observe the same parent build byte-identical snapshot content (the
     re-encoded update plus its metadata), so the content-addressed
     commit id they each produce is the same.
  2. The CAS write in `CommitStore.write_snapshot_cas/5` only commits
     if `:latest` still matches the expected parent. Callers who
     observed an older parent get `{:error, :parent_moved}`, which
     this module maps to the `:below_threshold` no-op reply.

  Callers who read `:latest` *after* the first snapshot landed see
  `chain_length = 0` — the snapshot is now `:latest` itself, so the
  walk stops immediately — and no-op without even attempting a CAS.

  ## Configuration

  The `:chain_length_threshold` opt overrides everything. When omitted,
  the value falls back to `Application.get_env(:commonplace,
  :snapshot_chain_threshold, @default_chain_length_threshold)`.
  """

  alias Commonplace.Store.{CommitStore, Snapshotter}

  @default_chain_length_threshold 100

  # CX-0nkq: per-doc debounce window. SnapshotTrigger.maybe_snapshot
  # is fired by the lazy reader path (DocBuilder.maybe_lazy_snapshot)
  # via Task.start, by the producer-side hook, by the sweeper, and by
  # the explicit CLI command. Under heavy reader pressure the Tasks
  # pile up at the CommitStore mailbox — fork on a deep tree timed
  # out at 5s under this contention. The debounce caps to one
  # snapshot attempt per doc per @debounce_window_ms, regardless of
  # how many readers triggered the path. Proper architectural fix
  # is a single-flight SnapshotWorker GenServer (still tracked in
  # CX-0nkq); this is the smallest viable relief.
  @debounce_window_ms 10_000
  @debounce_table :snapshot_trigger_debounce

  @doc false
  # Called from Commonplace.Application.start/2 to create the ETS
  # table that backs `recent_attempt?/2` + `record_attempt/1`. Public
  # so concurrent readers in any process can probe without going
  # through a GenServer.
  def init_debounce_table do
    if :ets.whereis(@debounce_table) == :undefined do
      try do
        :ets.new(@debounce_table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      rescue
        # Race: a parallel caller created the table between our
        # whereis check and our :ets.new — already exists is fine.
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @type maybe_snapshot_result ::
          {:ok, :snapshotted, Commonplace.Store.Commit.t()}
          | {:ok, :below_threshold, {:chain_length, non_neg_integer(), pos_integer()}}
          | {:ok, :debounced, {:debounce_window_ms, pos_integer()}}

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
    now_ms = Keyword.get(opts, :now, System.system_time(:millisecond))

    window =
      Keyword.get(
        opts,
        :debounce_window_ms,
        Application.get_env(:commonplace, :snapshot_trigger_debounce_window_ms, @debounce_window_ms)
      )

    cond do
      window > 0 and recent_attempt?(doc_uuid, now_ms, window) ->
        {:ok, :debounced, {:debounce_window_ms, window}}

      true ->
        record_attempt(doc_uuid, now_ms)
        do_maybe_snapshot(store, doc_uuid, threshold, opts)
    end
  end

  defp do_maybe_snapshot(store, doc_uuid, threshold, opts) do
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

  defp recent_attempt?(doc_uuid, now_ms, window) do
    init_debounce_table()

    case :ets.lookup(@debounce_table, doc_uuid) do
      [{^doc_uuid, last_ms}] -> now_ms - last_ms < window
      [] -> false
    end
  end

  defp record_attempt(doc_uuid, now_ms) do
    init_debounce_table()
    :ets.insert(@debounce_table, {doc_uuid, now_ms})
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
