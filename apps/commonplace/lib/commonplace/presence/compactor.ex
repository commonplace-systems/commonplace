defmodule Commonplace.Presence.Compactor do
  @moduledoc """
  Snapshot-append compaction for presence (and other state-vector-bloated)
  documents (CX-u7p).

  Long-lived presence docs accumulate one client_id per heartbeat under
  the writer-side bug fixed in CX-6g6 — by the time CX-6g6 lands, some
  docs have tens of thousands of distinct client_ids in their state
  vector and ~hundred-KB latest commit payloads. (The fix that stops new
  bloat is the stable per-doc client_id in `Commonplace.Presence`; this
  module cleans up docs that were already bloated before it landed.)

  The obvious cure — delete or rewrite the offending commits — is not
  available: the commit DAG is **append-only** (data is never removed),
  so we cannot shrink the *stored* history. What we *can* do is append
  one more commit that re-states the whole document under a single
  client_id, so that readers which apply only the latest commit see a
  small payload. That is the (B) "snapshot-append" strategy from the
  design doc:

  1. Load the doc via existing readers.
  2. Build a self-contained Yjs update under a single client_id via
     `Yelixer.Doc.snapshot_update/1`.
  3. Append it as a chained snapshot commit via
     `CommitStoreClient.create_snapshot_commit/4`.

  The new commit has a normal `parent_id` so replication still walks
  back through history. `DocBuilder.reconstruct_doc/2` short-circuits
  on the snapshot. Snapshot-style readers (e.g. `Presence.read/2`,
  which only applies the latest commit) immediately benefit from the
  smaller payload.

  ## Idempotency

  Calling `compact/2` twice in a row writes a second snapshot commit.
  This is intentional — the second snapshot is a no-op for readers
  (same observable state, same single-client state vector) but the
  append-only commit DAG sees one extra entry. If you need
  no-op-on-no-change behavior, gate the call with a state-vector size
  threshold check (the design doc proposes >256 client_ids as the
  trigger heuristic).
  """

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{BlockStore, Doc}

  @doc """
  Compact a doc by appending a snapshot commit.

  Returns `{:ok, commit}` on success or `{:error, :no_doc}` if the doc
  has no commits to compact.

  Although named under `Presence`, the compaction primitive is generic:
  any Yelixer-doc-backed UUID with state-vector bloat can be passed.
  Restricting it to presence is a usage convention, not a code
  enforcement.
  """
  def compact(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      :none ->
        {:error, :no_doc}

      {:ok, doc} ->
        # CX-umz: snapshot_update now returns {bytes, dm}. Presence
        # compaction doesn't need the DM (presence docs don't flow
        # through the late-edit translator), so we discard it here.
        {snapshot, _dm} = Doc.snapshot_update(doc)
        commit = CommitStoreClient.create_snapshot_commit(store, uuid, snapshot)
        {:ok, commit}
    end
  end

  @doc """
  Return the current state-vector size for a doc — the count of distinct
  client_ids in the materialized doc state. Useful for trigger policies
  (e.g. compact if size > 256).

  Returns 0 if the doc has no commits.
  """
  def state_vector_size(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      :none -> 0
      {:ok, doc} -> map_size(BlockStore.state_vector(doc.store).clocks)
    end
  end
end
