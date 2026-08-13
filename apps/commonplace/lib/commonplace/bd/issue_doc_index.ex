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
  pass. Historic issue documents are declared by a directory schema entry named
  `__issue.json`; going-forward documents are declared by their genesis commit's
  creation marker. Content shape never declares a document's type. It reports
  the declared issue-document denominator and enforces
  `LANDED ∪ REFUSED == input`; the live run is an operator daylight step.

  ## ⛔ What this index CANNOT see (measured 2026-08-13, CX-0hbs/CX-9wy4)

  THE INDEX DETECTS REGISTRATION-DENIED ORPHANS AND CANNOT SEE
  DOCUMENT-DENIED ONES. When only the parent-schema registration is refused,
  the orphan is caught: the document exists, its index entry exists, the
  parent link is absent, and `scan/2` returns it — measured
  `parent_schema_linked=false`, `torn_create_detected=true`.

  But the index marker rides atomically on the issue document's genesis
  commit, and `Schemas.create_text_doc/3` DISCARDS that commit's result. So
  under enforcement broad enough to deny the document write itself, the
  document and its index entry are BOTH silently absent and nothing fires —
  measured `new_docs=[]`, `issue_doc_index_delta=[]`.

  This is the index's acceptance being narrower than its purpose, not a
  configuration choice: a detector built to catch invisible tickets is blind
  in the case that would produce the most loss. It closes when
  `create_text_doc/3` binds and matches its commit result — the sixth site of
  the CX-0hbs discarded-return class, and the only one still open.

  A prior shape-based backfill may already have appended spurious CREATED rows.
  Corrected runs retain those immutable rows and append a separately visible
  supersession record. Effective entries and scans subtract recorded
  supersessions; no directory/VISIBLE entry is ever changed.

  A pre-marker orphan is invisible to declared facts BY CONSTRUCTION; its
  instrument is manual review of `supersessions/1`.
  """

  alias Commonplace.Bd.{Schemas, Workspace}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @creation_marker :bd_issue_doc_created
  @backfill_doc_limit 100_000
  @creation_log_limit 10_000
  @supersession_reason %{
    reason: :missing_issue_creation_declaration,
    detector: :schema_entry_or_creation_marker,
    schema_entry: "__issue.json"
  }

  @doc "Metadata marker that makes the issue-doc index row ride the same commit."
  def creation_metadata(metadata \\ %{}) when is_map(metadata) do
    metadata
    |> Map.put_new(:kind, :regular)
    |> Map.put(@creation_marker, true)
  end

  @doc "The effective CREATED set after subtracting visibly superseded backfill rows."
  def entries(store \\ CommitStoreClient) do
    MapSet.difference(raw_entries(store), Map.keys(supersessions(store)) |> MapSet.new())
  end

  @doc "The immutable correction records that visibly supersede spurious backfill rows."
  def supersessions(store \\ CommitStoreClient) do
    CommitStoreClient.bd_issue_doc_supersessions(store)
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
        historic_declared = historic_declared_issue_docs(doc_uuids, store)
        indexed = raw_entries(store)

        {creation_declared, marker_unknown} =
          indexed
          |> MapSet.difference(historic_declared)
          |> Enum.sort()
          |> Enum.reduce({MapSet.new(), []}, fn doc_uuid, {declared, unknown} ->
            case creation_marker_status(doc_uuid, store) do
              :marked -> {MapSet.put(declared, doc_uuid), unknown}
              :unmarked -> {declared, unknown}
              :unknown -> {declared, [doc_uuid | unknown]}
            end
          end)

        declared = MapSet.union(historic_declared, creation_declared)
        input = Enum.sort(declared)

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

        correction_input =
          indexed
          |> MapSet.difference(declared)
          |> MapSet.difference(MapSet.new(marker_unknown))
          |> Enum.sort()

        {superseded, supersession_refused} =
          Enum.reduce(correction_input, {[], []}, fn doc_uuid, {superseded, refused} ->
            case CommitStoreClient.append_bd_issue_doc_supersession(
                   store,
                   doc_uuid,
                   @supersession_reason
                 ) do
              :ok -> {[doc_uuid | superseded], refused}
              {:error, reason} -> {superseded, [%{doc_uuid: doc_uuid, reason: reason} | refused]}
            end
          end)

        {:ok,
         %{
           input: input,
           landed: landed,
           refused: refused,
           unaccounted: MapSet.difference(MapSet.new(input), accounted) |> Enum.sort(),
           superseded: Enum.reverse(superseded),
           supersession_refused: Enum.reverse(supersession_refused),
           supersession_unknown: Enum.reverse(marker_unknown),
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

  defp raw_entries(store) do
    CommitStoreClient.bd_issue_doc_uuids(store)
  end

  defp historic_declared_issue_docs(doc_uuids, store) do
    Enum.reduce(doc_uuids, MapSet.new(), fn doc_uuid, declared ->
      with {:ok, schema} <- Schemas.load_dir_schema(doc_uuid, store),
           {:ok, %{type: :doc, node_id: issue_doc_uuid}} <-
             Schema.get_entry(schema, Schemas.issue_filename()),
           true <- is_binary(issue_doc_uuid) do
        MapSet.put(declared, issue_doc_uuid)
      else
        _ -> declared
      end
    end)
  end

  defp creation_marker_status(doc_uuid, store) do
    commits = CommitStoreClient.commit_log(store, doc_uuid, limit: @creation_log_limit)

    cond do
      Enum.any?(commits, fn commit ->
        commit.doc_uuid == doc_uuid and Map.get(commit.metadata, @creation_marker) == true
      end) ->
        :marked

      length(commits) < @creation_log_limit ->
        :unmarked

      match?(%{parent_id: nil}, List.last(commits)) ->
        :unmarked

      true ->
        :unknown
    end
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
