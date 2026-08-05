defmodule Commonplace.Bd.Issue do
  @moduledoc """
  Issue CRUD on top of /bd/issues/<id>.iss directory docs.

  Spec: §3.1 (per-issue doc shape) and §3.2 (field-bag keys).

  P1: title and description stored as plain strings inside the
  field-bag JSON / a sibling text doc respectively. Live-collab
  YText shapes are P3.
  """

  alias Commonplace.Bd.{IdMint, Schemas, Workspace}
  alias Commonplace.Bd.Schemas.Issue
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @doc """
  Creates a new issue. Returns `{:ok, %Issue{}, dir_uuid}` or
  `{:error, reason}`.

  Mints an id from the workspace's `__meta.json` prefix, ensures
  /bd/issues/<id>.iss/ exists with __issue.json + description.txt,
  and stamps `created_at` / `updated_at`.
  """
  # `opts` (default `[]`) threads `:signing_context` down to every
  # commit this create issues (issue meta doc, description doc,
  # comments dir, the issues/ schema attach) — byte-compatible default,
  # same pattern as `update/5`.
  def create(root_uuid, attrs, store \\ CommitStoreClient, opts \\ []) do
    {:ok, meta} = Workspace.load_meta(root_uuid, store)

    with {:ok, id} <- IdMint.mint_issue_id(root_uuid, meta.prefix, store) do
      now = now_iso8601()

      issue = %Issue{
        id: id,
        title: Map.get(attrs, :title, ""),
        status: Map.get(attrs, :status, "open"),
        priority: Map.get(attrs, :priority, "p2"),
        type: Map.get(attrs, :type, "task"),
        owner: Map.get(attrs, :owner),
        created_at: Map.get(attrs, :created_at, now),
        updated_at: Map.get(attrs, :updated_at, now),
        labels: Map.get(attrs, :labels, []),
        needs: Map.get(attrs, :needs, []),
        done_when: Map.get(attrs, :done_when, "manual"),
        done_witness: Map.get(attrs, :done_witness, []),
        claimed_by: Map.get(attrs, :claimed_by),
        legacy_id: Map.get(attrs, :legacy_id),
        extra: Map.get(attrs, :extra, %{})
      }

      description = Map.get(attrs, :description, "")
      dir_uuid = build_issue_dir(issue, description, store, opts)
      :ok = add_issue_entry(root_uuid, id, dir_uuid, store, opts)

      {:ok, issue, dir_uuid}
    end
  end

  @doc """
  Reads an issue by id. Returns `{:ok, %Issue{}}` or `{:error, :not_found}`.
  """
  def show(root_uuid, id, store \\ CommitStoreClient) do
    case Workspace.issue_dir_uuid(root_uuid, id, store) do
      {:ok, dir_uuid} -> Schemas.load_issue(dir_uuid, store)
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Reads the description body of an issue.
  """
  def description(root_uuid, id, store \\ CommitStoreClient) do
    with {:ok, dir_uuid} <- Workspace.issue_dir_uuid(root_uuid, id, store),
         {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, Schemas.description_filename()),
         {:ok, doc} <- Commonplace.Tree.DocBuilder.reconstruct_doc(store, entry.node_id) do
      {:ok, Commonplace.Document.ContentType.get_content(doc) || ""}
    else
      :error -> {:error, :not_found}
      :none -> {:error, :not_found}
      err -> err
    end
  end

  @doc """
  Updates one or more fields on the issue. Stamps `updated_at`.
  Per spec §5.1, single-field updates are LWW per key on the
  `__issue.json` YMap; this v0 path does a read-modify-write through
  the JSON-backed text doc, which is the equivalent for our
  JSON-encoded substrate but does not yet preserve the per-key LWW
  semantics under concurrent writes (P3 will lift this to YMap-
  native storage when title-as-YText lands).
  """
  # `opts` (default `[]`) is threaded, untouched, down to
  # `Schemas.write_text_doc/4` — notably `:signing_context` for
  # updates that must land as signed commits. Default `[]` reproduces
  # prior (unsigned) behavior, same byte-compatible pattern as
  # `Tree.Merge.merge/4` / `Tree.Fork.fork/2`.
  def update(root_uuid, id, attrs, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, dir_uuid} <- Workspace.issue_dir_uuid(root_uuid, id, store) |> wrap_lookup(),
         {:ok, issue} <- Schemas.load_issue(dir_uuid, store) do
      issue =
        Enum.reduce(attrs, issue, fn {k, v}, acc -> apply_update_field(acc, k, v) end)

      issue = %{issue | updated_at: now_iso8601()}

      :ok = write_issue_meta(dir_uuid, issue, store, opts)

      {:ok, issue}
    end
  end

  @doc """
  Sets status, closed_at, closed_reason, and (Bd P2 Slice S3)
  done_witness in ONE update — one field-bag JSON write, one commit,
  so the flip from open to closed is atomic (no window where status
  reads closed but done_witness hasn't landed yet, or vice versa).

  `opts` carries `:reason` (the close reason), `:done_witness` (the
  close-gate's resolved witness list — `[]` for `done_when: "manual"`,
  `[cid_hex]` for a satisfied `pr_merge` requirement; defaults to `[]`,
  reproducing prior behavior for every pre-S3 caller that never set
  done_witness), and `:signing_context` (threaded through to
  `update/5` for a signed commit) — same keyword list, mirroring how
  `Tree.Fork`/`Tree.Merge` keep a single `opts` list rather than
  growing positional arity.

  This function does NOT enforce anything — per this module's
  moduledoc, `Commonplace.Bd.*` is the library layer. The caller
  (`ViewActionDispatch`'s `ticket_close` verb) is responsible for
  calling `Commonplace.Bd.WriteGuard.check/5` with
  `allow: [:status, :done_witness]` BEFORE calling this, and for
  resolving `done_witness` via `Commonplace.Bd.CloseGate` first.
  """
  def close(root_uuid, id, opts \\ [], store \\ CommitStoreClient) do
    reason = Keyword.get(opts, :reason)
    done_witness = Keyword.get(opts, :done_witness, [])
    signing_opts = Keyword.take(opts, [:signing_context])
    now = now_iso8601()

    with {:ok, dir_uuid} <- Workspace.issue_dir_uuid(root_uuid, id, store) |> wrap_lookup(),
         {:ok, current} <- Schemas.load_issue(dir_uuid, store) do
      closed_state = %{
        current
        | status: "closed",
          closed_at: now,
          closed_reason: reason,
          done_witness: done_witness,
          updated_at: now
      }

      # CX-gvbf (rework): the terminal-state pin
      # (Commonplace.Bd.Invariants' "closed-matches-pin" gate target).
      # Computed here, from the SAME field values this close is about
      # to write, so the pin's frozen subset
      # (status/done_when/done_witness — the only fields the invariant
      # reads) always matches what `update/5` below actually persists.
      # `update/5` unconditionally re-stamps `updated_at` with its own
      # `now_iso8601()` call a few microseconds after this one, so the
      # pin's `updated_at` can drift from the persisted value by that
      # much — harmless, since `updated_at` is outside the frozen
      # subset the invariant compares and isn't load-bearing for
      # anything else here.
      #
      # The pin does NOT land as a doc field any more (that made it
      # requester-writable state used as enforcement input — the same
      # merge that reopens a ticket could rewrite the pin that would
      # have caught it). Instead it rides the SIGNED CLOSE COMMIT's
      # `metadata`, mirroring the pr-provenance stamp
      # (`Commonplace.Bd.CloseGate`'s moduledoc /
      # `ViewActionDispatch.do_accept_merge/7`): metadata is
      # content-addressed (`Commonplace.Store.Commit.content_address/4`)
      # and covered by the signer's signature over the commit id, so
      # it is unforgeable without the signer's key and needs no trust
      # in the doc's own (editable) recorded status.
      # `Commonplace.Store.Commit.new/5` requires non-empty metadata to
      # carry a `:kind` — `:regular` matches every other non-snapshot
      # commit's tag.
      pin = Schemas.canonical_issue_json(closed_state)
      commit_metadata = %{kind: :regular, bd_terminal_pin: pin}
      update_opts = Keyword.put(signing_opts, :commit_metadata, commit_metadata)

      update(
        root_uuid,
        id,
        %{
          status: "closed",
          closed_at: now,
          closed_reason: reason,
          done_witness: done_witness
        },
        store,
        update_opts
      )
    end
  end

  @doc "Lists every issue currently in the workspace."
  def list(root_uuid, store \\ CommitStoreClient) do
    Workspace.list_issue_entries(root_uuid, store)
    |> Enum.map(fn entry ->
      case Schemas.load_issue(entry.node_id, store) do
        {:ok, issue} -> {issue, entry.node_id}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  ## Private

  defp build_issue_dir(%Issue{} = issue, description, store, opts) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()

    issue_json = Schemas.encode_issue(issue)
    issue_meta_uuid = Schemas.create_text_doc(issue_json, store, opts)
    desc_uuid = Schemas.create_text_doc(description, store, opts)
    comments_uuid = Schemas.create_dir_with_meta(nil, nil, store, opts)

    dir_doc =
      dir_doc
      |> Schema.add_file(Schemas.issue_filename(), issue_meta_uuid)
      |> Schema.add_file(Schemas.description_filename(), desc_uuid)
      |> Schema.add_directory("comments", comments_uuid)

    update = Encoding.encode_update(dir_doc)
    CommitStoreClient.create_commit(store, dir_uuid, update, nil, %{}, opts)
    dir_uuid
  end

  defp add_issue_entry(root_uuid, id, child_uuid, store, opts) do
    issues_uuid = Workspace.issues_dir_uuid(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(issues_uuid, store)
    schema = Schema.add_directory(schema, "#{id}.iss", child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, issues_uuid, update, %{}, opts)
    :ok
  end

  defp write_issue_meta(dir_uuid, %Issue{} = issue, store, opts) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
    Schemas.write_text_doc(entry.node_id, Schemas.encode_issue(issue), store, opts)
    :ok
  end

  defp apply_update_field(issue, :title, v), do: %{issue | title: v}
  defp apply_update_field(issue, :status, v), do: %{issue | status: v}
  defp apply_update_field(issue, :priority, v), do: %{issue | priority: v}
  defp apply_update_field(issue, :type, v), do: %{issue | type: v}
  defp apply_update_field(issue, :owner, v), do: %{issue | owner: v}
  defp apply_update_field(issue, :closed_at, v), do: %{issue | closed_at: v}
  defp apply_update_field(issue, :closed_reason, v), do: %{issue | closed_reason: v}
  defp apply_update_field(issue, :labels, v) when is_list(v), do: %{issue | labels: v}
  defp apply_update_field(issue, :needs, v) when is_list(v), do: %{issue | needs: v}
  defp apply_update_field(issue, :done_when, v), do: %{issue | done_when: v}
  defp apply_update_field(issue, :done_witness, v) when is_list(v), do: %{issue | done_witness: v}
  defp apply_update_field(issue, :claimed_by, v), do: %{issue | claimed_by: v}
  defp apply_update_field(issue, :legacy_id, v), do: %{issue | legacy_id: v}
  defp apply_update_field(issue, key, v) when is_atom(key), do: %{issue | extra: Map.put(issue.extra, Atom.to_string(key), v)}
  defp apply_update_field(issue, key, v) when is_binary(key), do: %{issue | extra: Map.put(issue.extra, key, v)}

  defp wrap_lookup({:ok, _} = ok), do: ok
  defp wrap_lookup(:error), do: {:error, :not_found}

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
