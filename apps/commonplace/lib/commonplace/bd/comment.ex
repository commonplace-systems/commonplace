defmodule Commonplace.Bd.Comment do
  @moduledoc """
  Comment CRUD on top of /bd/issues/<id>.iss/comments/c-<suffix>.json.

  Spec: §3.4 (comment doc shape) and §6 (lifecycle).

  P1: comments are JSON-backed text docs with `body` as a plain
  string. Live-collab YText is P3.

  ## CX-xmsd: every write result is CHECKED, and opts are threaded

  This module used to be the write-side of the CX-xxav phantom-success
  family. `add/4` threaded no signing opts and `add_file_entry/4`
  returned a hard-coded `:ok`, so under Mode-B enforce the store denied
  both commits (`{:error, {:trust_rejected, :unsigned}}`) while `add`
  answered `{:ok, %Comment{}}`. The 2026-08-05 tix migration reported
  "failed: 0" and landed ZERO comments; the destination count is what
  found it (CX-oc30: bd 6, tix 0).

  So: `opts` (notably `:signing_context`) are threaded into every
  commit, every store result is inspected, and a denial returns
  `{:error, {:comment_write_failed, stage, reason}}`. A success return
  from this module is a statement about the STORE's answer, not about
  this module's intentions.

  ### Ordering, and the impossible state

  A schema entry pointing at a doc that was never stored is a dangling
  reference nothing can repair (the store is append-only, so the entry
  survives forever). The doc create must therefore SUCCEED before the
  entry attach is attempted, and it does — the two stages are
  sequential, not concurrent, and stage 2 is unreachable unless stage 1
  landed.

  The reverse leftover is harmless and is reported rather than hidden:
  if the attach is denied, the comment doc is already in the store with
  nothing pointing at it. That is an orphan, not corruption (append-only
  storage, unreferenced doc, invisible to `list/3`), and the error names
  its uuid so a retry can be reasoned about.

  ### Not a gate

  This stays a LIBRARY: no `WriteGuard` call, no verb logic. The gated
  surface is `ticket_comment` / `ticket_comments_import` on
  `Commonplace.ViewActionDispatch`, which is where signing context,
  shape checks and batch accounting live.
  """

  alias Commonplace.Bd.{IdMint, Schemas, Workspace}
  alias Commonplace.Bd.Schemas.Comment
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @typedoc "Which store write failed. `add/5` can fail at either."
  @type stage :: :doc_create | :entry_attach | :body_write

  @doc """
  Adds a comment to the issue.

  Returns:

    * `{:ok, %Comment{}}` — both commits landed.
    * `{:ok, :noop}` — a comment with this id is already stored with
      byte-identical content (the backfill's idempotency case).
    * `{:error, {:exists_with_different_content, id}}` — same id,
      different bytes. A NAMED REFUSAL: this never overwrites.
    * `{:error, {:unlistable_comment_id, id}}` — the id would produce a
      filename `list/3` filters out (see `Schemas.comment_filename?/1`);
      writing it would create an invisible comment.
    * `{:error, {:comment_write_failed, stage, reason}}` — the store
      refused a write. `stage` is `:doc_create` or `:entry_attach`;
      an `:entry_attach` reason carries the orphaned doc uuid.
    * `{:error, :not_found}` / `{:error, :no_comments_dir}` — lookup.

  `opts` are passed to both commits; `:signing_context` is the one that
  matters under Mode-B enforce.
  """
  def add(root_uuid, issue_id, attrs, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, issue_dir} <- Workspace.issue_dir_uuid(root_uuid, issue_id, store) |> wrap_lookup(),
         {:ok, comments_dir} <- comments_dir_uuid(issue_dir, store) do
      comment_id = Map.get(attrs, :id) || IdMint.mint_comment_id()

      comment = %Comment{
        id: comment_id,
        author: Map.get(attrs, :author),
        created_at: Map.get(attrs, :created_at) || now_iso8601(),
        edited_at: nil,
        deleted: false,
        body: Map.get(attrs, :body, ""),
        reply_to: Map.get(attrs, :reply_to)
      }

      filename = Schemas.comment_filename(comment_id)
      encoded = Schemas.encode_comment(comment)

      # A comment whose filename `list/3` filters out would be stored,
      # referenced, and invisible — the destination count would read 0
      # over docs that exist, which is exactly the lie this ticket is
      # about, one layer down. Refuse before writing.
      if not Schemas.comment_filename?(filename) do
        {:error, {:unlistable_comment_id, comment_id}}
      else
        case existing_bytes(comments_dir, filename, store) do
          :absent -> write_new(comments_dir, filename, comment, encoded, store, opts)
          {:present, ^encoded} -> {:ok, :noop}
          {:present, _other} -> {:error, {:exists_with_different_content, comment_id}}
        end
      end
    end
  end

  @doc """
  Edits a comment's body. Stamps `edited_at`.

  `opts` are threaded to the write; a denied write is
  `{:error, {:comment_write_failed, :body_write, reason}}`, never a
  silent `{:ok, _}`.
  """
  def edit(root_uuid, issue_id, comment_id, body, store \\ CommitStoreClient, opts \\ [])
      when is_binary(body) do
    with {:ok, issue_dir} <- Workspace.issue_dir_uuid(root_uuid, issue_id, store) |> wrap_lookup(),
         {:ok, comments_dir} <- comments_dir_uuid(issue_dir, store),
         filename <- Schemas.comment_filename(comment_id),
         {:ok, comment} <- Schemas.load_comment(comments_dir, filename, store) do
      updated = %{comment | body: body, edited_at: now_iso8601()}

      case write_comment(comments_dir, filename, updated, store, opts) do
        :ok -> {:ok, updated}
        {:error, reason} -> {:error, {:comment_write_failed, :body_write, reason}}
      end
    end
  end

  @doc """
  Soft-deletes a comment (sets `deleted: true`). Per spec §6.1, the
  CRDT cannot reliably distinguish "key absent" from "key deleted",
  so deletion is a flag rather than a removal. Hard-delete is a
  P3+ compaction concern.

  Same checked-write contract as `edit/6`.
  """
  def soft_delete(root_uuid, issue_id, comment_id, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, issue_dir} <- Workspace.issue_dir_uuid(root_uuid, issue_id, store) |> wrap_lookup(),
         {:ok, comments_dir} <- comments_dir_uuid(issue_dir, store),
         filename <- Schemas.comment_filename(comment_id),
         {:ok, comment} <- Schemas.load_comment(comments_dir, filename, store) do
      updated = %{comment | deleted: true}

      case write_comment(comments_dir, filename, updated, store, opts) do
        :ok -> {:ok, updated}
        {:error, reason} -> {:error, {:comment_write_failed, :body_write, reason}}
      end
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

  # Stage 1 then stage 2, each checked. A failure at stage 2 names the
  # doc stage 1 left behind (see the moduledoc on orphans).
  defp write_new(comments_dir, filename, comment, encoded, store, opts) do
    case guarded(fn -> Schemas.create_text_doc_checked(encoded, store, opts) end) do
      {:ok, doc_uuid} ->
        case guarded(fn -> add_file_entry(comments_dir, filename, doc_uuid, store, opts) end) do
          :ok ->
            {:ok, comment}

          {:error, reason} ->
            {:error,
             {:comment_write_failed, :entry_attach,
              %{reason: reason, orphan_doc_uuid: doc_uuid}}}
        end

      {:error, reason} ->
        {:error, {:comment_write_failed, :doc_create, reason}}
    end
  end

  # The store's failure modes are not all values: a dead store or a
  # denied read inside `reconstruct_doc`/`load_dir_schema` surfaces as a
  # MatchError or a GenServer exit. Un-caught, those propagate as a
  # crash out of a function whose contract is `{:ok, _} | {:error, _}`
  # — a caller writing `case Comment.add(...)` would never see them and
  # a batch would lose its accounting. So they become `{:error, _}`
  # here, at the same boundary the checked returns land on.
  defp guarded(fun) do
    fun.()
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exited, reason}}
  end

  defp existing_bytes(comments_dir, filename, store) do
    case Schemas.load_raw_text(comments_dir, filename, store) do
      {:ok, bytes} when is_binary(bytes) -> {:present, bytes}
      _ -> :absent
    end
  end

  defp comments_dir_uuid(issue_dir, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(issue_dir, store),
         {:ok, entry} <- Schema.get_entry(schema, "comments") do
      {:ok, entry.node_id}
    else
      :error -> {:error, :no_comments_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_comment(comments_dir, filename, %Comment{} = comment, store, opts) do
    with {:ok, schema} <- Schemas.load_dir_schema(comments_dir, store),
         {:ok, entry} <- Schema.get_entry(schema, filename) do
      guarded(fn ->
        Schemas.write_text_doc_checked(entry.node_id, Schemas.encode_comment(comment), store, opts)
      end)
    else
      :error -> {:error, {:no_comment_entry, filename}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_file_entry(parent_uuid, name, child_uuid, store, opts) do
    with {:ok, schema} <- Schemas.load_dir_schema(parent_uuid, store) do
      schema = Schema.add_file(schema, name, child_uuid)
      update = Encoding.encode_update(schema)

      case CommitStoreClient.create_chained_commit(store, parent_uuid, update, %{}, opts) do
        {:error, reason} -> {:error, reason}
        _landed -> :ok
      end
    end
  end

  defp wrap_lookup({:ok, _} = ok), do: ok
  defp wrap_lookup(:error), do: {:error, :not_found}

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
