defmodule Commonplace.Bd.IssueDocIndex do
  @moduledoc """
  Create-time intent index and torn-create scan for bd issue documents.

  The two referents are deliberately different:

    * The index records **CREATED**. Its append-only
      `{:bd_issue_doc, doc_uuid} => true` entry is written in the same
      atomic store commit as the issue document's genesis commit.
    * The `/bd/issues/` directory records **VISIBLE**. Its schema links
      remain unchanged and remain the sole authority for listings and
      for whether an issue exists as a ticket.

  This is not a second ticket authority and is not the dual-write family
  rejected by the tix migration. The checkable invariant is
  `index ⊇ directory issue docs`; their difference is the recovery queue.

  `scan/2` is intentionally on-demand. Torn-create recovery is an operator-
  visible incident action, while ordinary listing must keep consulting only
  the directory and must not acquire scan latency or implicit recovery writes.
  The scan performs zero writes and there is no auto-link function here.

  `backfill/2` is the one-time exception to the standing no-whole-store-walk
  rule. It walks at most 100,000 current document heads in one operator-invoked
  pass, classifies issue documents, and refuses a larger store. It reports the
  declared issue-document denominator and enforces `LANDED ∪ REFUSED == input`;
  the live run is an operator daylight step.
  """

  alias Commonplace.Bd.{Schemas, Workspace}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @creation_marker :bd_issue_doc_created
  @backfill_doc_limit 100_000

  @doc "Metadata marker that makes the issue-doc index row ride the same commit."
  def creation_metadata(metadata \\ %{}) when is_map(metadata) do
    metadata
    |> Map.put_new(:kind, :regular)
    |> Map.put(@creation_marker, true)
  end

  @doc "The append-only set of issue document UUIDs recorded as CREATED."
  def entries(store \\ CommitStoreClient) do
    CommitStoreClient.bd_issue_doc_uuids(store)
  end

  @doc "Resolve directory-visible tickets to their `__issue.json` document UUIDs."
  def visible_issue_docs(root_uuid, store \\ CommitStoreClient) do
    root_uuid
    |> Workspace.list_issue_entries(store)
    |> Enum.reduce(MapSet.new(), fn entry, visible ->
      with {:ok, schema} <- Schemas.load_dir_schema(entry.node_id, store),
           {:ok, issue_entry} <- Schema.get_entry(schema, Schemas.issue_filename()) do
        MapSet.put(visible, issue_entry.node_id)
      else
        _ -> visible
      end
    end)
  end

  @doc "Return `{id, doc_uuid, created_at}` identities in CREATED minus VISIBLE."
  def scan(root_uuid, store \\ CommitStoreClient) do
    root_uuid
    |> torn_doc_uuids(store)
    |> Enum.flat_map(fn doc_uuid ->
      case load_identity(doc_uuid, store) do
        {:ok, {id, created_at}} -> [{id, doc_uuid, created_at}]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort()
  end

  @doc "Run the bounded one-time backfill. Production calls this through its gated verb."
  def backfill(_root_uuid, store \\ CommitStoreClient) do
    case CommitStoreClient.all_doc_uuids_bounded(store, @backfill_doc_limit) do
      {:ok, doc_uuid_set} ->
        doc_uuids = Enum.sort(doc_uuid_set)
        input = Enum.filter(doc_uuids, &issue_doc?(&1, store))

        {landed, refused} =
          Enum.reduce(input, {[], []}, fn doc_uuid, {landed, refused} ->
            case CommitStoreClient.append_bd_issue_doc(store, doc_uuid) do
              :ok -> {[doc_uuid | landed], refused}
              {:error, reason} -> {landed, [%{doc_uuid: doc_uuid, reason: reason} | refused]}
            end
          end)

        landed = Enum.reverse(landed)
        refused = Enum.reverse(refused)
        accounted = MapSet.new(landed ++ Enum.map(refused, & &1.doc_uuid))

        {:ok,
         %{
           input: input,
           landed: landed,
           refused: refused,
           unaccounted: MapSet.difference(MapSet.new(input), accounted) |> Enum.sort(),
           walked: length(doc_uuids),
           walk_limit: @backfill_doc_limit
         }}

      {:error, {:limit_exceeded, limit}} ->
        {:error, {:backfill_limit_exceeded, limit}}
    end
  end

  defp torn_doc_uuids(root_uuid, store) do
    MapSet.difference(entries(store), visible_issue_docs(root_uuid, store))
  end

  defp issue_doc?(doc_uuid, store) do
    match?({:ok, _identity}, load_identity(doc_uuid, store))
  end

  defp load_identity(doc_uuid, store) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, doc_uuid),
         json when is_binary(json) <- ContentType.get_content(doc),
         {:ok, issue} <- Schemas.decode_issue(json),
         id when is_binary(id) and id != "" <- issue.id,
         created_at when is_binary(created_at) and created_at != "" <- issue.created_at do
      {:ok, {id, created_at}}
    else
      _ -> {:error, :not_issue_doc}
    end
  end
end
