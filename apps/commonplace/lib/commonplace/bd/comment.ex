defmodule Commonplace.Bd.Comment do
  @moduledoc """
  Comment CRUD on top of /bd/issues/<id>.iss/comments/c-<suffix>.json.

  Spec: §3.4 (comment doc shape) and §6 (lifecycle).

  P1: comments are JSON-backed text docs with `body` as a plain
  string. Live-collab YText is P3.
  """

  alias Commonplace.Bd.{IdMint, Schemas, Workspace}
  alias Commonplace.Bd.Schemas.Comment
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @doc """
  Adds a comment to the issue. Returns `{:ok, %Comment{}}` or
  `{:error, reason}`.
  """
  def add(root_uuid, issue_id, attrs, store \\ CommitStoreClient) do
    with {:ok, issue_dir} <- Workspace.issue_dir_uuid(root_uuid, issue_id, store) |> wrap_lookup(),
         {:ok, comments_dir} <- comments_dir_uuid(issue_dir, store) do
      comment_id = Map.get(attrs, :id, IdMint.mint_comment_id())
      now = now_iso8601()

      comment = %Comment{
        id: comment_id,
        author: Map.get(attrs, :author),
        created_at: Map.get(attrs, :created_at, now),
        edited_at: nil,
        deleted: false,
        body: Map.get(attrs, :body, ""),
        reply_to: Map.get(attrs, :reply_to)
      }

      filename = Schemas.comment_filename(comment_id)
      doc_uuid = Schemas.create_text_doc(Schemas.encode_comment(comment), store)
      :ok = add_file_entry(comments_dir, filename, doc_uuid, store)

      {:ok, comment}
    end
  end

  @doc "Edits a comment's body. Stamps `edited_at`."
  def edit(root_uuid, issue_id, comment_id, body, store \\ CommitStoreClient) when is_binary(body) do
    with {:ok, issue_dir} <- Workspace.issue_dir_uuid(root_uuid, issue_id, store) |> wrap_lookup(),
         {:ok, comments_dir} <- comments_dir_uuid(issue_dir, store),
         filename <- Schemas.comment_filename(comment_id),
         {:ok, comment} <- Schemas.load_comment(comments_dir, filename, store) do
      updated = %{comment | body: body, edited_at: now_iso8601()}

      :ok = write_comment(comments_dir, filename, updated, store)
      {:ok, updated}
    end
  end

  @doc """
  Soft-deletes a comment (sets `deleted: true`). Per spec §6.1, the
  CRDT cannot reliably distinguish "key absent" from "key deleted",
  so deletion is a flag rather than a removal. Hard-delete is a
  P3+ compaction concern.
  """
  def soft_delete(root_uuid, issue_id, comment_id, store \\ CommitStoreClient) do
    with {:ok, issue_dir} <- Workspace.issue_dir_uuid(root_uuid, issue_id, store) |> wrap_lookup(),
         {:ok, comments_dir} <- comments_dir_uuid(issue_dir, store),
         filename <- Schemas.comment_filename(comment_id),
         {:ok, comment} <- Schemas.load_comment(comments_dir, filename, store) do
      updated = %{comment | deleted: true}

      :ok = write_comment(comments_dir, filename, updated, store)
      {:ok, updated}
    end
  end

  @doc "Lists every comment on the issue, including soft-deleted ones."
  def list(root_uuid, issue_id, store \\ CommitStoreClient) do
    with {:ok, issue_dir} <- Workspace.issue_dir_uuid(root_uuid, issue_id, store) |> wrap_lookup(),
         {:ok, comments_dir} <- comments_dir_uuid(issue_dir, store),
         {:ok, schema} <- Schemas.load_dir_schema(comments_dir, store) do
      Schema.list_entries(schema)
      |> Enum.filter(fn e -> Schemas.comment_filename?(e.name) end)
      |> Enum.map(fn entry ->
        case Schemas.load_comment(comments_dir, entry.name, store) do
          {:ok, comment} -> comment
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.created_at)
    else
      _ -> []
    end
  end

  ## Private

  defp comments_dir_uuid(issue_dir, store) do
    {:ok, schema} = Schemas.load_dir_schema(issue_dir, store)

    case Schema.get_entry(schema, "comments") do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> {:error, :no_comments_dir}
    end
  end

  defp write_comment(comments_dir, filename, %Comment{} = comment, store) do
    {:ok, schema} = Schemas.load_dir_schema(comments_dir, store)
    {:ok, entry} = Schema.get_entry(schema, filename)
    Schemas.write_text_doc(entry.node_id, Schemas.encode_comment(comment), store)
    :ok
  end

  defp add_file_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end

  defp wrap_lookup({:ok, _} = ok), do: ok
  defp wrap_lookup(:error), do: {:error, :not_found}

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
