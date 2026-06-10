defmodule Commonplace.Store.GC do
  @moduledoc """
  Garbage collection — **detection only**. Finds orphaned documents:
  those present in the CommitStore but not reachable from a given root.

  It walks the schema tree from the root, collects every reachable UUID,
  and subtracts that from the set of all document UUIDs in the store; the
  remainder are orphans. `find_orphans/2` returns the `{reachable,
  orphaned}` MapSets; `report/2` wraps them with counts.

  **Nothing is ever deleted.** The CommitStore is append-only (data is
  never removed), so "GC" here means *identifying* unreferenced docs —
  for auditing, debugging dangling references, or a future external
  archival step — not reclaiming their space. And an orphan is only
  orphaned relative to the root you pass: a doc reachable from a
  *different* root that wasn't supplied still shows up as an orphan here.
  """

  alias Commonplace.Tree.Walk
  alias Commonplace.Tree.Schema
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Store.CommitStoreClient

  @doc """
  Find orphaned document UUIDs — documents in the store that are not
  reachable from the given root UUID.

  Returns `{reachable, orphaned}` where both are MapSets.
  """
  def find_orphans(root_uuid, store \\ CommitStoreClient) do
    loader = fn uuid ->
      case CommitStoreClient.latest_commit(store, uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema()
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema()
      end
    end

    reachable = Walk.reachable_uuids(root_uuid, loader)
    all_uuids = CommitStoreClient.all_doc_uuids(store)
    orphaned = MapSet.difference(all_uuids, reachable)

    {reachable, orphaned}
  end

  @doc """
  Report orphaned documents without deleting anything.
  Returns a map with stats and the orphan UUIDs.
  """
  def report(root_uuid, store \\ CommitStoreClient) do
    {reachable, orphaned} = find_orphans(root_uuid, store)

    %{
      reachable_count: MapSet.size(reachable),
      orphaned_count: MapSet.size(orphaned),
      orphaned_uuids: orphaned
    }
  end

  @doc """
  Archive the current state of every orphaned doc to a JSONL file at
  `dest_path`, **without deleting anything** (R8 part b / CX-tdkq.8). This
  is the external archival step the module's "GC" detection always
  anticipated: an operator can stash or inspect unreferenced docs' state
  before deciding their fate. Reclaiming store space — *deleting* the
  archived orphans from the append-only store — is a separate, gated
  decision (CX-tdkq.17), deliberately NOT done here.

  Each JSONL line is a self-contained snapshot of one orphan:

      {"uuid": <uuid>,
       "latest_commit": <hex commit id>,
       "state_b64": <base64 of the doc's full reconstructed Yjs update>}

  `state_b64` is the *reconstructed full state* (not just the latest
  delta), so a line is enough to re-materialize the doc elsewhere.

  Returns `{:ok, %{archived: n, skipped: m, path: dest_path}}` — `skipped`
  counts orphans with no reconstructable state (defensive; normally 0).
  """
  def archive_orphans(root_uuid, dest_path, store \\ CommitStoreClient) do
    {_reachable, orphaned} = find_orphans(root_uuid, store)

    {lines, archived, skipped} =
      Enum.reduce(orphaned, {[], 0, 0}, fn uuid, {acc, a, s} ->
        case archive_line(uuid, store) do
          {:ok, line} -> {[line | acc], a + 1, s}
          :skip -> {acc, a, s + 1}
        end
      end)

    contents = if lines == [], do: "", else: Enum.join(Enum.reverse(lines), "\n") <> "\n"
    File.write!(dest_path, contents)

    {:ok, %{archived: archived, skipped: skipped, path: dest_path}}
  end

  defp archive_line(uuid, store) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, uuid),
         {:ok, commit} <- CommitStoreClient.latest_commit(store, uuid) do
      line =
        Jason.encode!(%{
          "uuid" => uuid,
          "latest_commit" => Base.encode16(commit.id, case: :lower),
          "state_b64" => Base.encode64(Yelixer.Encoding.encode_update(doc))
        })

      {:ok, line}
    else
      _ -> :skip
    end
  end
end
