defmodule Commonplace.Reflog.Restore do
  @moduledoc """
  The RESTORE half of the reflog (CX-0t2r): reading a past checkpoint
  back into a usable subtree.

  `Commonplace.Reflog.Snapshot` writes the checkpoints — this module
  reads them. Three public functions, deliberately kept separate (this
  is the load-bearing seam, do not blur it):

    * `list_checkpoints/3` — enumerate available checkpoints for an
      owner. Read-only.
    * `resolve/3` — turn one checkpoint commit into a flat
      `%{path => {:file, doc_uuid, commit_id_hex}}` map. **Pure,
      read-only, zero writes.**
    * `materialize_branch/4` — the ONE (so far) consumer of `resolve/3`:
      builds a brand-new subtree of fresh docs from a resolved map and
      grafts it onto the workspace root as a named branch. This is
      where writes happen.

  A future in-place-reroot materializer (pointing existing paths back
  at restored content instead of branching) is a second, independent
  consumer of `resolve/3` — it should be addable without touching
  `resolve/3` at all. Keep it that way.

  ## What the recorded checkpoint format actually supports

  This took some archaeology, so it's recorded here rather than left
  as tribal knowledge.

  A directory's `__snapshot` doc (`Snapshot.build_reflog_doc/3`) is a
  flat map:

      %{
        "__schema_cid" => <hex commit_id of this dir's OWN data-schema
                            commit at checkpoint time, or absent if the
                            data dir had no commits yet>,
        "__timestamp"  => <ISO8601 string>,
        "file.txt"     => <hex commit_id of file.txt's OWN latest
                            commit at checkpoint time>,
        "subdir"       => <hex commit_id of subdir's own reflog dir's
                            __snapshot doc commit, at checkpoint time —
                            NOT the subdir's data-schema commit>
      }

  Two things this map does **not** carry, that resolution needs:

    1. **Doc UUIDs.** Every value is a bare commit id. A commit id
       alone doesn't say which document it belongs to — `commit_id` is
       a content hash, not a pointer.
    2. **Entry type (file vs. dir).** The map has no type tag; `"doc"` /
       `"dir"` distinction lives only in the schema, not the reflog
       snapshot.

  Both gaps are closed by combining two things the store already gives
  us for free:

    * `Commit.doc_uuid` — every stored commit carries the uuid of the
      doc it was written to (`Commonplace.Store.Commit` calls this
      "Historical... debugging only": it is **not** folded into the
      commit's content-addressed id, so it is not Merkle-verified or
      tamper-evident). `CommitStoreClient.get_commit/2` is a pure
      point-read by commit id that returns it. Resolution leans on this
      field to go from "a bare commit id" back to "which document did
      this commit land on" — the only place in this module that trusts
      a non-content-addressed field, and safe here because restore only
      ever runs against the LOCAL store the caller already trusts (the
      same trust boundary `checkpoint/3` itself writes under).
    * `__schema_cid` — recorded specifically so resolution has an entry
      point: `get_commit(schema_cid).doc_uuid` gives the data
      directory's own uuid, and `reconstruct_doc_at(store, that_uuid,
      schema_cid)` replays the schema exactly as it stood at checkpoint
      time. THAT schema is where the type tag and every entry's real
      `node_id` (doc uuid) come from — the reflog map's per-entry hex
      values are then just looked up by name against this schema-typed
      entry list, joining "what type / what uuid" (from the historical
      schema) with "what commit" (from the reflog map).
    * For a `:dir` entry, the recorded hex commit id is itself the
      child's `__snapshot` doc's commit id, so `get_commit(...).doc_uuid`
      on THAT commit hands us the child snapshot doc's uuid directly —
      no name-based navigation of the (live, mutable) reflog tree is
      needed to recurse; the child snapshot lookup is fully determined
      by the values already in hand.

  What is **not** recoverable: any entry whose name was excluded from
  the recorded map at checkpoint time. As of CX-0t2r, presence-transient
  `.usr` entries (configurable via
  `Application.get_env(:commonplace, :reflog_exclude_suffixes, [".usr"])`)
  are deliberately excluded from the write side to keep heartbeat churn
  from defeating the checkpoint cursor. `resolve/3` cannot distinguish
  "excluded at write time" from "genuinely absent at that path" — both
  simply produce no entry in the resolved map. If a data dir had zero
  commits at checkpoint time (`schema_cid_hex == nil`), the whole
  subtree resolves to `%{}`.

  ## Acceptance scope (see `restore_test.exs`)

  The test suite for this module covers the BRANCH materializer
  (`materialize_branch/4`) only — round-trip fidelity, enforce-mode
  signing, and the resolve-is-read-only seam property. An in-place
  materializer, when it exists, needs its own acceptance tests; passing
  this suite says nothing about that path.
  """

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Document.ContentType
  alias Commonplace.Crypto.{NodeIdentity, SigningContext}
  alias Commonplace.WriterHand
  alias Commonplace.Reflog.Snapshot

  require Logger

  @default_owner "server"

  @doc """
  List available checkpoints for `owner` under `root_uuid`'s reflog
  branch, newest first. Each entry is `{commit_id, timestamp,
  signer_id}` — one per commit on the root reflog dir's `__snapshot`
  doc (each such commit IS one checkpoint).

  Read-mostly: `Snapshot.ensure_reflog_branch/3` mints the `__reflog`
  scaffolding if it doesn't exist yet (mirrors `checkpoint/3`'s own
  behavior) — a no-op once a single checkpoint has ever been taken.

  Filters out the synthetic genesis commit `create_chained_commit/5`
  auto-mints as the first commit of every fresh `__snapshot` doc
  (`metadata.kind == :genesis`) — it carries no checkpoint content, so
  counting it as a checkpoint would off-by-one every listing.
  """
  @spec list_checkpoints(GenServer.server(), String.t(), String.t()) ::
          [{binary(), DateTime.t(), String.t() | nil}]
  def list_checkpoints(store \\ CommitStoreClient, root_uuid, owner \\ @default_owner) do
    case root_snapshot_uuid(store, root_uuid, owner) do
      {:ok, snapshot_uuid} ->
        CommitStoreClient.commit_log(store, snapshot_uuid)
        |> Enum.reject(&genesis_commit?/1)
        |> Enum.map(fn commit -> {commit.id, commit.timestamp, commit.signer_id} end)

      :error ->
        []
    end
  end

  defp genesis_commit?(%{metadata: %{kind: :genesis}}), do: true
  defp genesis_commit?(_), do: false

  @doc """
  Resolve the root reflog dir's own `__snapshot` doc uuid for `owner`
  under `root_uuid` — the handle `resolve/3` needs as its second
  argument. Exposed separately from `list_checkpoints/3` so callers
  (the CLI, tests) that already have a checkpoint commit id in hand
  don't have to re-derive it by re-listing.
  """
  @spec root_snapshot_uuid(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | :error
  def root_snapshot_uuid(store \\ CommitStoreClient, root_uuid, owner \\ @default_owner) do
    {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, owner, store)
    owner_schema = load_schema(owner_uuid, store)

    case Schema.get_entry(owner_schema, "__snapshot") do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> :error
    end
  end

  @doc """
  Resolve one checkpoint into a flat `%{path => {:file, doc_uuid,
  commit_id_hex}}` map. `snapshot_doc_uuid` is a reflog dir's own
  `__snapshot` doc uuid (the root's, from `root_snapshot_uuid/3`, for a
  whole-tree restore); `checkpoint_commit_id` is a commit id on that
  doc's chain (from `list_checkpoints/3`).

  Pure and read-only — issues no writes. See the moduledoc's "What the
  recorded checkpoint format actually supports" for exactly what this
  can and cannot recover.

  Returns `{:ok, resolved}` or `{:error, reason}`.
  """
  @spec resolve(GenServer.server(), String.t(), binary()) ::
          {:ok, %{optional(String.t()) => {:file, String.t(), String.t()}}}
          | {:error, term()}
  def resolve(store \\ CommitStoreClient, snapshot_doc_uuid, checkpoint_commit_id) do
    case single_commit_doc(store, checkpoint_commit_id, snapshot_doc_uuid) do
      {:ok, doc} ->
        content = ContentType.get_content(doc) || %{}
        resolve_from_content(store, content)

      :none ->
        {:error, {:checkpoint_not_found, checkpoint_commit_id}}

      {:error, _} = err ->
        err
    end
  end

  # Every write on the `__snapshot` doc's chain (`Snapshot.build_reflog_doc/3`)
  # mints a BRAND NEW `Yelixer.Doc.new(client_id: WriterHand.for_doc(uuid))`
  # each round — the SAME stable client_id every time, but starting a fresh
  # op-clock from 0, not continuing from the previous round's state. That
  # stable-client choice is deliberate (CX-41qg.3, to cap state-vector
  # growth) and is safe for the doc's actual read path
  # (`Snapshot.read_snapshot/2` uses `reconstruct_snapshot/2`: apply only
  # the LATEST commit's own update to a fresh doc). It is NOT safe to
  # chain-replay multiple rounds together via `DocBuilder.reconstruct_doc/2`
  # or `reconstruct_doc_at/4` — round 2's ops reuse (client, clock) pairs
  # round 1 already used, so Yjs's idempotent merge treats them as
  # already-applied duplicates and silently drops them, leaving the replay
  # stuck on round 1's content forever. (Confirmed empirically while
  # building this module — a naive `reconstruct_doc_at` implementation
  # returned checkpoint 1's content for checkpoint 2's commit id.)
  #
  # The fix mirrors `reconstruct_snapshot/2` but at an arbitrary historical
  # commit rather than always the latest: fetch that ONE commit's own
  # `update` bytes (a self-contained full state, by construction) and apply
  # it alone to a throwaway fresh doc. Same hazard, same fix, for the DATA
  # DIRECTORY's schema commits reached via `__schema_cid` below — schema
  # docs are documented as "always store full snapshots"
  # (`DocBuilder.reconstruct_snapshot/2`'s moduledoc) for the same reason.
  #
  # `expected_doc_uuid`, when given, is a defensive cross-check: the
  # checkpoint commit id the caller handed us should belong to the doc
  # uuid the caller believes it does.
  defp single_commit_doc(store, commit_id, expected_doc_uuid \\ nil) do
    case CommitStoreClient.get_commit(store, commit_id) do
      {:ok, %{doc_uuid: doc_uuid}} when not is_nil(expected_doc_uuid) and doc_uuid != expected_doc_uuid ->
        {:error, {:commit_doc_mismatch, commit_id, expected: expected_doc_uuid, got: doc_uuid}}

      {:ok, commit} ->
        Yelixer.Encoding.apply_update(Yelixer.Doc.new(), commit.update)

      :none ->
        :none
    end
  end

  defp resolve_from_content(store, content) when is_map(content) do
    case Map.get(content, "__schema_cid") do
      nil ->
        # No schema_cid recorded — the data dir had no commits yet at
        # checkpoint time, so it had no entries either. Empty subtree.
        {:ok, %{}}

      schema_cid_hex ->
        resolve_via_schema_cid(store, schema_cid_hex, content)
    end
  end

  defp resolve_from_content(_store, _content), do: {:ok, %{}}

  defp resolve_via_schema_cid(store, schema_cid_hex, content) do
    schema_commit_id = Base.decode16!(schema_cid_hex, case: :lower)

    case single_commit_doc(store, schema_commit_id) do
      {:ok, schema_doc} ->
        entries =
          Schema.list_entries(schema_doc)
          |> Enum.reject(&String.starts_with?(&1.name, "__"))

        resolve_entries(store, entries, content)

      :none ->
        {:error, {:schema_commit_not_found, schema_cid_hex}}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_entries(store, entries, content) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case Map.get(content, entry.name) do
        nil ->
          # Not in the recorded map — either excluded at write time
          # (e.g. `.usr`) or a schema/reflog inconsistency. Either way
          # there is nothing to resolve for this name; skip it rather
          # than fail the whole checkpoint.
          {:cont, {:ok, acc}}

        hex ->
          resolve_entry(store, entry, hex, acc)
      end
    end)
  end

  defp resolve_entry(_store, %Schema.Entry{type: :doc, node_id: node_id, name: name}, hex, acc) do
    {:cont, {:ok, Map.put(acc, name, {:file, node_id, hex})}}
  end

  defp resolve_entry(store, %Schema.Entry{type: :dir, name: name}, hex, acc) do
    commit_id = Base.decode16!(hex, case: :lower)

    case CommitStoreClient.get_commit(store, commit_id) do
      {:ok, child_commit} ->
        case resolve(store, child_commit.doc_uuid, commit_id) do
          {:ok, child_resolved} ->
            prefixed =
              Map.new(child_resolved, fn {path, v} -> {name <> "/" <> path, v} end)

            {:cont, {:ok, Map.merge(acc, prefixed)}}

          {:error, _} = err ->
            {:halt, err}
        end

      :none ->
        {:halt, {:error, {:child_snapshot_commit_not_found, hex}}}
    end
  end

  defp resolve_entry(_store, _entry, _hex, acc), do: {:cont, {:ok, acc}}

  @doc """
  Materialize a `resolve/3` result as a brand-new branch grafted onto
  `root_uuid`. For every `{path, {:file, doc_uuid, commit_id_hex}}`,
  reconstructs the doc's exact state at that commit and writes it as a
  fresh doc under a new uuid (branch-point commit chained to the
  source commit, mirroring `Commonplace.Tree.Fork`'s per-doc
  materialization). Fresh directory schema docs are assembled to match
  `path`'s structure, and the new root directory is attached to
  `root_uuid` under `opts[:as]` (default `"restored-<ISO8601 basic
  timestamp>"`).

  All writes are node-signed by default via
  `Commonplace.Crypto.NodeIdentity.signing_context/0` (falls back to
  unsigned only if no node identity is available — a bare
  library-embedding/test context) — this is a node-authored system
  operation, not a session's own write, the same posture
  `Snapshot.checkpoint/3` takes (CX-cl65's lesson: enforce-mode
  round-trips need a real signer, not just a permissive test). Pass
  `opts[:signing_context]` to override with a specific context.

  Returns `{:ok, %{root_entry: name, docs: count}}` where `count` is
  every fresh doc minted (files + directory schemas, including the new
  root).
  """
  @spec materialize_branch(GenServer.server(), map(), String.t(), keyword()) ::
          {:ok, %{root_entry: String.t(), docs: non_neg_integer()}}
  def materialize_branch(store \\ CommitStoreClient, resolved, root_uuid, opts \\ []) do
    signing_opts = resolve_signing_opts(opts)
    name = Keyword.get(opts, :as) || default_branch_name()

    tree = build_tree(resolved)
    {new_root_uuid, docs} = materialize_tree(store, tree, signing_opts)

    attach_to_root(store, root_uuid, name, new_root_uuid, signing_opts)

    {:ok, %{root_entry: name, docs: docs}}
  end

  defp resolve_signing_opts(opts) do
    case Keyword.fetch(opts, :signing_context) do
      {:ok, %SigningContext{} = sc} ->
        [signing_context: sc]

      :error ->
        case NodeIdentity.signing_context() do
          {:ok, sc} ->
            [signing_context: sc]

          {:error, reason} ->
            Logger.debug(
              "Reflog restore: no node identity (#{inspect(reason)}), writing unsigned"
            )

            []
        end
    end
  end

  defp default_branch_name do
    "restored-" <> DateTime.to_iso8601(DateTime.utc_now(), :basic)
  end

  # Turns %{"notes/todo.md" => file_entry, ...} into a nested map keyed
  # by path segment, leaves holding the file_entry tuple.
  defp build_tree(resolved) do
    Enum.reduce(resolved, %{}, fn {path, file_entry}, acc ->
      parts = String.split(path, "/", trim: true)
      put_in_tree(acc, parts, file_entry)
    end)
  end

  defp put_in_tree(tree, [last], file_entry), do: Map.put(tree, last, file_entry)

  defp put_in_tree(tree, [head | rest], file_entry) do
    sub = Map.get(tree, head, %{})
    Map.put(tree, head, put_in_tree(sub, rest, file_entry))
  end

  # Depth-first: children materialize before the parent's schema is
  # written, mirroring Fork's ordering. Returns {new_dir_uuid, doc_count}.
  defp materialize_tree(store, tree, signing_opts) do
    {schema, count} =
      Enum.reduce(tree, {Schema.new_schema(), 0}, fn {name, node}, {schema_acc, count_acc} ->
        case node do
          {:file, doc_uuid, commit_id_hex} ->
            {new_uuid, added} = materialize_file(store, doc_uuid, commit_id_hex, signing_opts)
            {Schema.add_file(schema_acc, name, new_uuid), count_acc + added}

          subtree when is_map(subtree) ->
            {child_uuid, added} = materialize_tree(store, subtree, signing_opts)
            {Schema.add_directory(schema_acc, name, child_uuid), count_acc + added}
        end
      end)

    new_dir_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(schema)
    {meta, commit_opts} = split_opts(signing_opts)
    CommitStoreClient.create_chained_commit(store, new_dir_uuid, update, meta, commit_opts)

    {new_dir_uuid, count + 1}
  end

  defp materialize_file(store, source_doc_uuid, commit_id_hex, signing_opts) do
    commit_id = Base.decode16!(commit_id_hex, case: :lower)
    new_uuid = UUID.uuid4()

    update =
      case DocBuilder.reconstruct_doc_at(store, source_doc_uuid, commit_id) do
        {:ok, doc} -> Yelixer.Encoding.encode_update(doc)
        :none -> Yelixer.Encoding.encode_update(Yelixer.Doc.new())
      end

    {meta, commit_opts} = split_opts(signing_opts)
    # Branch-point commit: chains to the exact source commit that was
    # checkpointed, same provenance shape as Fork's leaf materialization.
    CommitStoreClient.create_commit(store, new_uuid, update, commit_id, meta, commit_opts)

    {new_uuid, 1}
  end

  defp attach_to_root(store, root_uuid, name, new_root_uuid, signing_opts) do
    schema =
      case DocBuilder.reconstruct_snapshot(store, root_uuid, client_id: WriterHand.for_doc(root_uuid)) do
        {:ok, doc} -> doc
        :none -> Schema.new_schema()
      end

    schema = Schema.add_directory(schema, name, new_root_uuid)
    update = Yelixer.Encoding.encode_update(schema)
    {meta, commit_opts} = split_opts(signing_opts)
    CommitStoreClient.create_chained_commit(store, root_uuid, update, meta, commit_opts)
  end

  defp split_opts([]), do: {%{}, []}
  defp split_opts(signing_opts), do: {%{}, signing_opts}

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid, client_id: WriterHand.for_doc(uuid)) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
