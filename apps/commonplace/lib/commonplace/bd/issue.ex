defmodule Commonplace.Bd.Issue do
  @moduledoc """
  Issue CRUD on top of /bd/issues/<id>.iss directory docs.

  Spec: §3.1 (per-issue doc shape) and §3.2 (field-bag keys).

  P1: title and description stored as plain strings inside the
  field-bag JSON / a sibling text doc respectively. Live-collab
  YText shapes are P3.
  """

  alias Commonplace.Bd.{IdMint, IssueDocIndex, Schemas, Workspace}
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
      create_with_id(
        root_uuid,
        build_with_id(id, attrs),
        Map.get(attrs, :description, ""),
        store,
        opts
      )
    end
  end

  @doc """
  Builds — PURELY, writing nothing — the `%Issue{}` an id + attrs bag
  would be stored as. CX-6cz3 (tix-authority migration §7): the gated
  `ticket_create` / `ticket_import` verbs must hash and gate the
  EXACT record they are about to persist, so the struct is built once
  here, handed to `Commonplace.Bd.WriteGuard.check_create/4`, and then
  handed to `create_with_id/5` — one derivation, no chance for the
  gated value and the written value to drift apart.

  `created_at` / `updated_at` fall back to now when the attrs bag
  doesn't carry them (an import carries bd's originals; a fresh
  create doesn't).
  """
  @spec build_with_id(String.t(), map()) :: Issue.t()
  def build_with_id(id, attrs) when is_binary(id) and is_map(attrs) do
    now = now_iso8601()

    %Issue{
      id: id,
      title: Map.get(attrs, :title) || "",
      status: Map.get(attrs, :status) || "open",
      priority: Map.get(attrs, :priority) || "p2",
      type: Map.get(attrs, :type) || "task",
      owner: Map.get(attrs, :owner),
      created_at: Map.get(attrs, :created_at) || now,
      updated_at: Map.get(attrs, :updated_at) || now,
      closed_at: Map.get(attrs, :closed_at),
      closed_reason: Map.get(attrs, :closed_reason),
      labels: Map.get(attrs, :labels) || [],
      needs: Map.get(attrs, :needs) || [],
      done_when: Map.get(attrs, :done_when) || "manual",
      done_witness: Map.get(attrs, :done_witness) || [],
      claimed_by: Map.get(attrs, :claimed_by),
      legacy_id: Map.get(attrs, :legacy_id),
      extra: Map.get(attrs, :extra) || %{}
    }
  end

  @doc """
  The ONE supplied-id creation primitive (CX-6cz3). Writes `issue`
  verbatim under `/bd/issues/<issue.id>.iss/`, with `description` in
  the sibling text doc.

  This supersedes the two private `create_with_fixed_id` copies that
  used to live in `Commonplace.Bd.Importer` and
  `Commonplace.Bd.Migrate` — both raw-store writes with no
  `WriteGuard` involvement (tix design §7's step-1 VERIFY finding).
  Like everything else in `Commonplace.Bd.*` it enforces NOTHING
  itself: the guarantee is that no UNGATED caller exists, checked by
  `Commonplace.Bd.SuppliedIdCreationScanTest` (build condition 3).
  Callers must run `Commonplace.Bd.WriteGuard.check_create/4` on the
  SAME struct first.

  `opts[:commit_metadata]` rides onto the `__issue.json` GENESIS
  commit — the doc whose chain `Commonplace.Bd.Invariants` walks for
  the terminal pin, and the same place `Commonplace.Bd.Issue.close/4`
  stamps it. That is how an import's provenance stamp and freeze pin
  reach the one chain that reads them. The rest of `opts`
  (`:signing_context`) threads to every commit this create issues.
  """
  @spec create_with_id(String.t(), Issue.t(), String.t(), module() | atom(), keyword()) ::
          {:ok, Issue.t(), String.t()} | {:error, term()}
  def create_with_id(root_uuid, issue, description \\ "", store \\ CommitStoreClient, opts \\ [])

  def create_with_id(root_uuid, %Issue{id: id} = issue, description, store, opts)
      when is_binary(id) and id != "" do
    if Keyword.has_key?(opts, :ticket_create_deadline) do
      with {:ok, dir_uuid} <- build_issue_dir_deadline(issue, description, store, opts),
           :ok <- add_issue_entry_deadline(root_uuid, id, dir_uuid, store, plain_opts(opts)) do
        {:ok, issue, dir_uuid}
      end
    else
      with dir_uuid when is_binary(dir_uuid) <- build_issue_dir(issue, description, store, opts),
           :ok <- add_issue_entry(root_uuid, id, dir_uuid, store, plain_opts(opts)) do
        {:ok, issue, dir_uuid}
      end
    end
  end

  @doc """
  The commit metadata that stamps a ticket's terminal-state pin
  (CX-gvbf). `close/4` and CX-6cz3's `ticket_import` both stamp
  through THIS function — ruling (a)'s "import stamping rides the
  SAME mechanism as close's, never a second separately-controlled
  minting path".

  There is no code-level pause knob on pin-minting: `close/4` stamps
  unconditionally, so import does too. The standing
  "(a)-validator → main, DEPLOY → fleet, then pin resumes" rule is
  OPERATIONAL (a deploy-sequencing rule about the fleet), not a
  runtime flag — see CX-6cz3's build report.
  """
  @spec terminal_pin_metadata(Issue.t()) :: map()
  def terminal_pin_metadata(%Issue{} = issue) do
    %{bd_terminal_pin: Schemas.canonical_issue_json(issue)}
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
  Overwrites the issue's description doc (the `description.txt`
  sibling — descriptions are NOT part of the `__issue.json` field
  bag). Added for CX-6cz3's import update path: without it a
  re-imported record could only ever change field-bag values, so an
  edited bd description silently never landed. Enforcement-free like
  the rest of this module — the import verb runs the guard on the
  record first.
  """
  @spec write_description(String.t(), String.t(), String.t(), module() | atom(), keyword()) ::
          :ok | {:error, term()}
  def write_description(root_uuid, id, text, store \\ CommitStoreClient, opts \\ [])
      when is_binary(text) do
    with {:ok, dir_uuid} <- Workspace.issue_dir_uuid(root_uuid, id, store) |> wrap_lookup(),
         {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, Schemas.description_filename()) |> wrap_lookup() do
      Schemas.write_text_doc(entry.node_id, text, store, opts)
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
      issue = apply_attrs(issue, attrs)
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
      # CX-6cz3: the pin itself comes from `terminal_pin_metadata/1`,
      # the ONE minting site — `ticket_import`'s stamping of an
      # imported closed ticket rides this exact function (ruling (a):
      # never a second, separately-controlled minting path).
      commit_metadata = Map.put(terminal_pin_metadata(closed_state), :kind, :regular)
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

  # `opts[:commit_metadata]` is deliberately applied to the
  # `__issue.json` doc ONLY (CX-6cz3): that is the chain
  # `Commonplace.Bd.Invariants` walks for the terminal pin and the
  # chain a drift scanner reads for the import provenance stamp. The
  # description doc, the comments dir and the parent schema entry get
  # `plain_opts/1` — same signing context, no stamp.
  defp build_issue_dir(%Issue{} = issue, description, store, opts) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()
    plain = plain_opts(opts)

    issue_json = Schemas.encode_issue(issue)

    issue_opts =
      Keyword.update(
        opts,
        :commit_metadata,
        IssueDocIndex.creation_metadata(),
        &IssueDocIndex.creation_metadata/1
      )

    issue_meta_uuid = Schemas.create_text_doc(issue_json, store, issue_opts)
    desc_uuid = Schemas.create_text_doc(description, store, plain)
    comments_uuid = Schemas.create_dir_with_meta(nil, nil, store, plain)

    dir_doc =
      dir_doc
      |> Schema.add_file(Schemas.issue_filename(), issue_meta_uuid)
      |> Schema.add_file(Schemas.description_filename(), desc_uuid)
      |> Schema.add_directory("comments", comments_uuid)

    update = Encoding.encode_update(dir_doc)

    case CommitStoreClient.create_commit(store, dir_uuid, update, nil, %{}, plain) do
      {:error, reason} -> {:error, reason}
      _commit -> dir_uuid
    end
  end

  defp build_issue_dir_deadline(%Issue{} = issue, description, store, opts) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()
    plain = plain_opts(opts)

    issue_json = Schemas.encode_issue(issue)

    issue_opts =
      Keyword.update(
        opts,
        :commit_metadata,
        IssueDocIndex.creation_metadata(),
        &IssueDocIndex.creation_metadata/1
      )

    with {:ok, issue_meta_uuid} <-
           Schemas.create_text_doc_checked(
             issue_json,
             store,
             named_deadline_opts(issue_opts, "issue doc")
           ),
         {:ok, desc_uuid} <-
           Schemas.create_text_doc_checked(
             description,
             store,
             named_deadline_opts(plain, "description doc")
           ),
         {:ok, comments_uuid} <-
           Schemas.create_dir_with_meta_checked(
             nil,
             nil,
             store,
             named_deadline_opts(plain, "comments dir")
           ) do
      dir_doc =
        dir_doc
        |> Schema.add_file(Schemas.issue_filename(), issue_meta_uuid)
        |> Schema.add_file(Schemas.description_filename(), desc_uuid)
        |> Schema.add_directory("comments", comments_uuid)

      update = Encoding.encode_update(dir_doc)

      case CommitStoreClient.create_commit(
             store,
             dir_uuid,
             update,
             nil,
             %{},
             named_deadline_opts(plain, "issue dir schema")
           ) do
        {:error, reason} -> {:error, reason}
        _commit -> {:ok, dir_uuid}
      end
    end
  end

  defp plain_opts(opts), do: Keyword.delete(opts, :commit_metadata)

  defp named_deadline_opts(opts, document) do
    if Keyword.has_key?(opts, :ticket_create_deadline) do
      Keyword.put(opts, :ticket_create_document, document)
    else
      opts
    end
  end

  defp add_issue_entry(root_uuid, id, child_uuid, store, opts) do
    issues_uuid = Workspace.issues_dir_uuid(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(issues_uuid, store)
    schema = Schema.add_directory(schema, "#{id}.iss", child_uuid)
    update = Encoding.encode_update(schema)

    case CommitStoreClient.create_chained_commit(store, issues_uuid, update, %{}, opts) do
      {:error, reason} -> {:error, reason}
      _commit -> :ok
    end
  end

  defp add_issue_entry_deadline(root_uuid, id, child_uuid, store, opts) do
    issues_uuid = Workspace.issues_dir_uuid(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(issues_uuid, store)
    schema = Schema.add_directory(schema, "#{id}.iss", child_uuid)
    update = Encoding.encode_update(schema)

    case CommitStoreClient.create_chained_commit(
           store,
           issues_uuid,
           update,
           %{},
           named_deadline_opts(opts, "issues-dir link")
         ) do
      {:error, reason} -> {:error, reason}
      _commit -> :ok
    end
  end

  defp write_issue_meta(dir_uuid, %Issue{} = issue, store, opts) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
    Schemas.write_text_doc(entry.node_id, Schemas.encode_issue(issue), store, opts)
    :ok
  end

  @doc """
  Applies an `update/5`-shaped attrs bag to an issue struct, PURELY.
  Exposed (CX-6cz3) so the gated import verb can compute the exact
  would-be-stored record for its content-hash no-op check with the
  SAME code that performs the write — a separate "what would this
  become" implementation is how a no-op check quietly stops matching
  reality, and a no-op skips the gate.
  """
  @spec apply_attrs(Issue.t(), map()) :: Issue.t()
  def apply_attrs(%Issue{} = issue, attrs) when is_map(attrs) do
    Enum.reduce(attrs, issue, fn {k, v}, acc -> apply_update_field(acc, k, v) end)
  end

  @doc """
  The fields `apply_attrs/2` writes into first-class struct keys (as
  opposed to the `extra` catch-all). CX-6cz3's import delta is
  restricted to these: `created_at` / `updated_at` / `id` have no
  update clause, so passing them as "changes" would silently bury
  them in `extra` instead of updating them.
  """
  @spec writable_fields() :: [atom()]
  def writable_fields do
    [
      :title,
      :status,
      :priority,
      :type,
      :owner,
      :closed_at,
      :closed_reason,
      :labels,
      :needs,
      :done_when,
      :done_witness,
      :claimed_by,
      :legacy_id,
      :extra
    ]
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
  # CX-6cz3: without this clause an `extra:` attr fell into the
  # atom-key catch-all below and nested itself as `extra["extra"]` on
  # every re-import — the round-trip fidelity the importer's
  # extra-field preservation exists for, lost on the second pass. The
  # incoming map REPLACES `extra` (an import is a derivation from the
  # source record, so the source record is authoritative over it).
  defp apply_update_field(issue, :extra, v) when is_map(v), do: %{issue | extra: v}
  defp apply_update_field(issue, key, v) when is_atom(key), do: %{issue | extra: Map.put(issue.extra, Atom.to_string(key), v)}
  defp apply_update_field(issue, key, v) when is_binary(key), do: %{issue | extra: Map.put(issue.extra, key, v)}

  defp wrap_lookup({:ok, _} = ok), do: ok
  defp wrap_lookup(:error), do: {:error, :not_found}

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
