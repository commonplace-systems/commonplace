defmodule Commonplace.Store.Snapshotter do
  @moduledoc """
  Builds snapshot *payloads* — the raw material a snapshot commit is
  written from: a deterministic Yjs update plus a *derivation map*
  (CX-6sc / CX-bgy, build 5). This module produces the bytes; the
  caller does the content-addressed write.

  ## Why a snapshot needs a derivation map

  A snapshot re-encodes a document's entire current state into one
  self-contained Yjs update. But it does not preserve the original CRDT
  item identities: `Yelixer.Doc.snapshot_update/1` replays the state
  into a *fresh* doc, minting brand-new ids (`{client_id, clock}`
  tuples) for every item. That fresh id-space is a new *namespace* (a
  new "epoch") — and any edit a peer authored against the *old*
  namespace now refers to item ids that no longer exist here. (A
  namespace is the identity space a doc's items live in, named by the
  snapshot commit that opened it; the vocabulary is owned by
  `Commonplace.Store.Namespace`.)

  The derivation map is the dictionary that keeps those would-be-orphaned
  edits recoverable. It records, for each item the snapshot minted,
  which source item it was derived from:

      %{source_namespace_id => %{new_id => old_id}}

  where `new_id` and `old_id` are the `{client_id, clock}` item tuples
  above, and `source_namespace_id` is the parent snapshot's namespace
  (a commit id). The late-edit translation pipeline (`Commonplace.Store.Translator`,
  build 6) reads this map to re-express an old-epoch edit's operations
  in terms of the snapshot's new ids, so a cross-epoch edit can still be
  applied instead of silently dropped. (`Commonplace.LateEditAutoTranslator`
  is the sync-path hook that drives it.)

  ## Determinism is load-bearing

  `snapshot_update/1` is byte-deterministic across Yelixer instances
  that hold the same logical state (verified by
  `Yelixer.SnapshotDeterminismTest`). That is what makes
  "deterministic-anyone" snapshotting (CX-umz) work: any node that
  observes the same parent independently builds *byte-identical*
  snapshot content, so the content-addressed commit id they each compute
  is the same — and the compare-and-swap write in
  `CommitStore.write_snapshot_cas/5` collapses concurrent attempts into
  one commit instead of forking history. Both `CommitStore.snapshot/2`
  and `Commonplace.SnapshotTrigger` route through `build_snapshot/3` so
  they agree on the payload bytes.

  That determinism has one subtlety `build/1` enforces by hand:
  `snapshot_update/1` mints new ids using the *source* doc's own
  `client_id`, which is random for a freshly reconstructed doc. Two
  independent reconstructions of the same logical state would otherwise
  disagree on the minter and produce different bytes. So `build/1`
  overwrites it with a deterministic function of the source's own
  contents — the smallest `client_id` present among the source's items
  (0 if empty) — before running the replay.

  ## Map shape and multi-parent snapshots

  For an MVP single-parent snapshot there is exactly one top-level key:
  the parent's namespace id (its `current_namespace`, falling back to
  the parent commit's own id for a doc's first snapshot). `snapshot_parents`
  is a list, and the outer map is keyed by namespace, precisely so a
  snapshot that one day collapses more than one epoch can carry one
  entry per source namespace — that future composition across epochs is
  build 6's job; here there is always exactly one.
  """

  @snapshotter_version 1

  @doc "The current snapshotter version tag (binds into the commit id)."
  def snapshotter_version, do: @snapshotter_version

  @doc """
  Build a complete snapshot payload (update bytes + umbrella metadata)
  for `doc_uuid` with `parent_commit` as the snapshot's source state.

  Reconstructs the doc from history, runs it through the deterministic
  snapshotter, wraps the derivation map under the parent's
  `current_namespace` key, and stamps the current snapshotter version.
  Callers combine the returned `{update_bytes, metadata}` with a
  content-addressed write (signed commit / CAS write / etc.).

  Both `CommitStore.snapshot/2` and `Commonplace.SnapshotTrigger`
  route through this so they agree on payload bytes (load-bearing for
  deterministic-anyone — CX-umz).
  """
  @typedoc """
  A built snapshot payload, or a guard trip. `{:error, {:nested_subtypes,
  names}}` (CX-tdkq.5 R5) means the source carries CRDT sub-types nested
  inside maps/arrays that `Yelixer.Doc.snapshot_update/1` cannot replay —
  snapshotting would silently drop their state, so the caller must refuse
  and retain the full chain instead. See `build_payload/2`.
  """
  @type build_result ::
          {:ok, binary(), map()}
          | {:error, {:nested_subtypes, [String.t()]}}

  @spec build_snapshot(GenServer.server(), String.t(), Commonplace.Store.Commit.t()) ::
          build_result()
  def build_snapshot(server, doc_uuid, parent_commit) do
    server
    |> reconstruct_source(doc_uuid, parent_commit)
    |> build_payload(parent_commit)
  end

  @doc """
  Build a snapshot payload from an already-reconstructed source doc, or
  refuse if the doc cannot be snapshotted without data loss.

  Returns `{:ok, update_bytes, metadata}` for a snapshottable doc, or
  `{:error, {:nested_subtypes, names}}` when the source carries CRDT
  sub-types nested inside maps/arrays (R5 guard, CX-tdkq.5). Those sub-types
  are dropped by `Yelixer.Doc.snapshot_update/1`; cutting the snapshot would
  silently lose their state, so the only safe outcome is to NOT snapshot —
  the full commit chain is retained, which preserves the nested CRDT. This
  turns a delayed, data-losing trap into a visible no-op (callers emit
  telemetry / a clear error). See the design-doc edict in
  docs/architecture-review.md §8 R5.
  """
  @spec build_payload(Yelixer.Doc.t(), Commonplace.Store.Commit.t()) :: build_result()
  def build_payload(%Yelixer.Doc{} = source_doc, parent_commit) do
    case Yelixer.Doc.nested_subtype_names(source_doc) do
      [] ->
        {update_bytes, dm_inner} = build(source_doc)

        parent_namespace =
          Commonplace.Store.Namespace.current_namespace(parent_commit) || parent_commit.id

        metadata = %{
          snapshot_parents: [parent_namespace],
          derivation_map: %{parent_namespace => dm_inner},
          snapshotter_version: snapshotter_version()
        }

        {:ok, update_bytes, metadata}

      names ->
        {:error, {:nested_subtypes, names}}
    end
  end

  defp reconstruct_source(_server, _uuid, %{metadata: %{kind: :genesis}}) do
    Yelixer.Doc.new()
  end

  defp reconstruct_source(server, uuid, _parent) do
    case Commonplace.Tree.DocBuilder.reconstruct_doc(server, uuid) do
      {:ok, doc} ->
        # CX-saix: a replayed doc's type registry doesn't know `content`
        # (no CRDT item carries the registration) — without hydrating
        # from the envelope, snapshot_update silently skips the content
        # type entirely (an xml outline snapshotted to EMPTY). Hydrate
        # exactly like readers do.
        Commonplace.Document.ContentType.hydrate(doc)

      :none ->
        Yelixer.Doc.new()
    end
  end

  @doc """
  Build a snapshot payload from a source Yelixer doc.

  Returns `{update_bytes, derivation_map_inner}`. The caller is
  responsible for wrapping the inner map under the source snapshot
  hash key when assembling metadata.
  """
  @spec build(Yelixer.Doc.t()) :: {binary(), %{optional(tuple()) => tuple()}}
  def build(%Yelixer.Doc{} = source) do
    # `Yelixer.Doc.new/1` picks a random client_id when one isn't
    # specified, and `snapshot_update/1` uses the source doc's
    # client_id as the minter for the fresh doc's items. To get the
    # deterministic-anyone property we need two independent
    # reconstructions of the same logical state to produce the same
    # snapshot bytes — so overwrite `source.client_id` with a
    # deterministic function of the source's observable state before
    # running the replay.
    #
    # CX-umz: `snapshot_update/1` now folds the derivation-map build
    # into the same deterministic pass, returning `{bytes, dm_inner}`.
    # Callers wrap the inner map under the source snapshot hash key.
    deterministic = %{source | client_id: deterministic_client_id(source)}
    Yelixer.Doc.snapshot_update(deterministic)
  end

  # Deterministic client_id for the snapshot doc: the smallest
  # client_id present in the source's items, or 0 if the source is
  # empty. Smallest-by-integer is stable across BEAM nodes and doesn't
  # depend on map iteration order.
  defp deterministic_client_id(%Yelixer.Doc{store: store}) do
    # CX-w1fw: client_ids/1 includes clients whose only blocks are
    # still in client_pending — Map.keys(store.clients) alone would
    # miss them.
    case Yelixer.BlockStore.client_ids(store) do
      [] -> 0
      clients -> Enum.min(clients)
    end
  end
end
