defmodule Commonplace.Bd.Schemas do
  @moduledoc """
  Encode/decode helpers for the Beads-on-Commonplace JSON-backed
  documents. Same shape as `Commonplace.MUD.Schemas` — JSON inside a
  Yelixer text doc, parsed on read, re-encoded on write.

  Spec: /home/jes/commonplace-plan/docs/beads-on-commonplace.md §3.

  P1 scope: title and description are plain strings inside the
  field-bag for now (the spec calls for title-as-nested-YText and
  description-as-YText sibling doc; the live-collab affordance is P3
  per §11 / §12).
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.WriterHand
  alias Yelixer.Doc
  alias Yelixer.Encoding

  @issue_file "__issue.json"
  # CX-xmsd: two accepted comment-id shapes, and the second one is not
  # cosmetic. `Comment.list/3` FILTERS the comments dir through this
  # pattern, so a comment written under a name it rejects is stored,
  # referenced, and permanently invisible — a destination count of 0
  # over docs that exist. bd's own comment ids are UUIDv7 strings
  # (`019eb2d7-d95e-7184-a0d6-9de7a813d426`), which the minted `c-<suffix>`
  # form rejects, so the archive backfill would have landed 196
  # unlistable docs. Ids are PRESERVED across the migration (the same
  # rule the ticket ids got), which means the pattern is what widens.
  # `Comment.add/5` refuses any id whose filename this rejects, so the
  # invisible-write state is unreachable rather than merely unlikely.
  @comment_filename_pattern ~r/^(c-[a-z0-9]+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.json$/
  @meta_file "__meta.json"
  @deps_file "deps.json"
  @description_file "description.txt"

  @valid_statuses ~w(open in_progress blocked review closed wontfix)
  @valid_priorities ~w(p0 p1 p2 p3)
  @valid_types ~w(feature bug task epic spike)

  defmodule Issue do
    @enforce_keys [:id]
    defstruct id: nil,
              title: "",
              status: "open",
              priority: "p2",
              type: "task",
              owner: nil,
              created_at: nil,
              updated_at: nil,
              closed_at: nil,
              closed_reason: nil,
              labels: [],
              # Bd P2 graph-vocabulary lift (Slice S1 Part 1): promoted
              # out of `extra` so they get first-class encode/decode +
              # ref-type validation (Commonplace.Bd.WriteGuard).
              needs: [],
              done_when: "manual",
              done_witness: [],
              claimed_by: nil,
              legacy_id: nil,
              extra: %{}

    @type need_ref :: %{required(String.t()) => String.t()}

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            status: String.t(),
            priority: String.t(),
            type: String.t(),
            owner: String.t() | nil,
            created_at: String.t() | nil,
            updated_at: String.t() | nil,
            closed_at: String.t() | nil,
            closed_reason: String.t() | nil,
            labels: [String.t()],
            needs: [need_ref()],
            done_when: String.t(),
            done_witness: [String.t()],
            claimed_by: String.t() | nil,
            legacy_id: String.t() | nil,
            extra: map()
          }
  end

  defmodule Comment do
    @enforce_keys [:id]
    defstruct id: nil,
              author: nil,
              created_at: nil,
              edited_at: nil,
              deleted: false,
              body: "",
              reply_to: nil

    @type t :: %__MODULE__{
            id: String.t(),
            author: String.t() | nil,
            created_at: String.t() | nil,
            edited_at: String.t() | nil,
            deleted: boolean(),
            body: String.t(),
            reply_to: String.t() | nil
          }
  end

  defmodule Edge do
    @enforce_keys [:from, :to, :kind]
    defstruct from: nil,
              to: nil,
              kind: "blocks",
              created_at: nil,
              created_by: nil

    @type t :: %__MODULE__{
            from: String.t(),
            to: String.t(),
            kind: String.t(),
            created_at: String.t() | nil,
            created_by: String.t() | nil
          }

    def key(%__MODULE__{from: f, to: t, kind: k}), do: "#{f}::#{t}::#{k}"
    def key(from, to, kind) when is_binary(from) and is_binary(to) and is_binary(kind), do: "#{from}::#{to}::#{kind}"
  end

  defmodule Label do
    @enforce_keys [:name]
    defstruct name: nil,
              color: nil,
              description: ""

    @type t :: %__MODULE__{
            name: String.t(),
            color: String.t() | nil,
            description: String.t()
          }
  end

  defmodule Meta do
    defstruct prefix: "CX",
              statuses: ~w(open in_progress blocked review closed wontfix),
              priorities: ~w(p0 p1 p2 p3),
              types: ~w(feature bug task epic spike),
              default_owner: nil,
              extra: %{}

    @type t :: %__MODULE__{
            prefix: String.t(),
            statuses: [String.t()],
            priorities: [String.t()],
            types: [String.t()],
            default_owner: String.t() | nil,
            extra: map()
          }
  end

  def issue_filename, do: @issue_file
  def description_filename, do: @description_file
  def meta_filename, do: @meta_file
  def deps_filename, do: @deps_file
  def comment_filename(id), do: "#{id}.json"

  def valid_statuses, do: @valid_statuses
  def valid_priorities, do: @valid_priorities
  def valid_types, do: @valid_types

  def comment_filename?(name), do: Regex.match?(@comment_filename_pattern, name)

  # ---- Issue encoding ----

  def encode_issue(%Issue{} = i), do: i |> issue_to_map() |> Jason.encode!()

  def decode_issue(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        known =
          ~w(id title status priority type owner created_at updated_at closed_at closed_reason labels needs done_when done_witness claimed_by legacy_id)

        extra = Map.drop(m, known)

        {:ok,
         %Issue{
           id: Map.get(m, "id", ""),
           title: Map.get(m, "title", ""),
           status: Map.get(m, "status", "open"),
           priority: Map.get(m, "priority", "p2"),
           type: Map.get(m, "type", "task"),
           owner: Map.get(m, "owner"),
           created_at: Map.get(m, "created_at"),
           updated_at: Map.get(m, "updated_at"),
           closed_at: Map.get(m, "closed_at"),
           closed_reason: Map.get(m, "closed_reason"),
           labels: Map.get(m, "labels", []),
           needs: Map.get(m, "needs", []),
           done_when: Map.get(m, "done_when", "manual"),
           done_witness: Map.get(m, "done_witness", []),
           claimed_by: Map.get(m, "claimed_by"),
           legacy_id: Map.get(m, "legacy_id"),
           extra: extra
         }}

      err ->
        err
    end
  end

  defp issue_to_map(%Issue{} = i) do
    base = %{
      "id" => i.id,
      "title" => i.title,
      "status" => i.status,
      "priority" => i.priority,
      "type" => i.type,
      "owner" => i.owner,
      "created_at" => i.created_at,
      "updated_at" => i.updated_at,
      "closed_at" => i.closed_at,
      "closed_reason" => i.closed_reason,
      "labels" => i.labels,
      "needs" => i.needs,
      "done_when" => i.done_when,
      "done_witness" => i.done_witness,
      "claimed_by" => i.claimed_by,
      "legacy_id" => i.legacy_id
    }

    Map.merge(base, i.extra)
  end

  @doc """
  CX-gvbf: canonical JSON of `issue`'s LOGICAL state, for use as a
  terminal-state pin or any other content-addressed comparison over
  the app's own decoded structs (never leaf CRDT bytes — see the long
  comment on `write_text_doc/4` for why a bytes-CID is the wrong tool
  here).

  The pin is no longer stored as a doc field (that made it
  requester-writable state used as enforcement input — the same merge
  that reopens a ticket could also rewrite the pin that would have
  caught it). It now rides the SIGNED CLOSE COMMIT's `metadata`
  instead (`Commonplace.Bd.Issue.close/4` stamps it via
  `:commit_metadata`; `Commonplace.Bd.Invariants` reads it back by
  walking commit history) — so there is no `"terminal_pin"` key on the
  issue itself to exclude from its own hash any more; this just hashes
  the issue's full logical state.

  Determinism is REQUIRED, not cosmetic: two replicas (or the same
  replica at two different times) computing this from the same
  logical state must produce byte-identical output, or the
  closed-matches-pin comparison in `Commonplace.Bd.Invariants` becomes
  meaningless. Plain `Jason.encode!/1` over a regular map does not
  promise that — Erlang map iteration order is a property of the map's
  internal representation, not a stable contract — so this sorts every
  object's keys explicitly before encoding via `Jason.OrderedObject`
  (which Jason's encoder serializes in list order, unlike a bare map).
  """
  @spec canonical_issue_json(Issue.t()) :: String.t()
  def canonical_issue_json(%Issue{} = issue) do
    issue
    |> issue_to_map()
    |> canonicalize()
    |> Jason.encode!()
  end

  @doc """
  Deterministic JSON for an arbitrary decoded map/list — the same
  key-sorted encoding `canonical_issue_json/1` uses, exposed
  (CX-6cz3) so an import can content-hash the RAW bd record it
  derived a ticket from without a second, subtly-different
  canonicalization. Erlang map order is not a contract; two
  canonicalizations that disagree would make the provenance stamp's
  `sources_pin` un-reproducible for the drift scanner.
  """
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value), do: value |> canonicalize() |> Jason.encode!()

  # Recursively rewrites maps into `Jason.OrderedObject`s with
  # lexicographically-sorted keys, and walks into lists, so nested
  # structures (e.g. `needs`, `extra`) are just as deterministic as
  # the top level.
  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  # ---- Comment encoding ----

  def encode_comment(%Comment{} = c) do
    Jason.encode!(%{
      "id" => c.id,
      "author" => c.author,
      "created_at" => c.created_at,
      "edited_at" => c.edited_at,
      "deleted" => c.deleted,
      "body" => c.body,
      "reply_to" => c.reply_to
    })
  end

  def decode_comment(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        {:ok,
         %Comment{
           id: Map.get(m, "id", ""),
           author: Map.get(m, "author"),
           created_at: Map.get(m, "created_at"),
           edited_at: Map.get(m, "edited_at"),
           deleted: Map.get(m, "deleted", false),
           body: Map.get(m, "body", ""),
           reply_to: Map.get(m, "reply_to")
         }}

      err ->
        err
    end
  end

  # ---- Edge encoding (one entry in deps.json) ----

  def encode_edge_value(%Edge{} = e) do
    %{
      "from" => e.from,
      "to" => e.to,
      "kind" => e.kind,
      "created_at" => e.created_at,
      "created_by" => e.created_by
    }
  end

  def decode_edge_value(map) when is_map(map) do
    %Edge{
      from: Map.get(map, "from", ""),
      to: Map.get(map, "to", ""),
      kind: Map.get(map, "kind", "blocks"),
      created_at: Map.get(map, "created_at"),
      created_by: Map.get(map, "created_by")
    }
  end

  def encode_deps(edges) when is_list(edges) do
    edges
    |> Enum.map(fn %Edge{} = e -> {Edge.key(e), encode_edge_value(e)} end)
    |> Enum.into(%{})
    |> Jason.encode!()
  end

  def decode_deps(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        edges =
          m
          |> Enum.map(fn {_key, val} -> decode_edge_value(val) end)

        {:ok, edges}

      err ->
        err
    end
  end

  # ---- Label encoding ----

  def encode_label(%Label{} = l) do
    Jason.encode!(%{
      "name" => l.name,
      "color" => l.color,
      "description" => l.description
    })
  end

  def decode_label(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        {:ok,
         %Label{
           name: Map.get(m, "name", ""),
           color: Map.get(m, "color"),
           description: Map.get(m, "description", "")
         }}

      err ->
        err
    end
  end

  # ---- Meta encoding ----

  def encode_meta(%Meta{} = m) do
    base = %{
      "prefix" => m.prefix,
      "statuses" => m.statuses,
      "priorities" => m.priorities,
      "types" => m.types,
      "default_owner" => m.default_owner
    }

    Map.merge(base, m.extra) |> Jason.encode!()
  end

  def decode_meta(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        known = ~w(prefix statuses priorities types default_owner)
        extra = Map.drop(map, known)

        {:ok,
         %Meta{
           prefix: Map.get(map, "prefix", "CX"),
           statuses: Map.get(map, "statuses", @valid_statuses),
           priorities: Map.get(map, "priorities", @valid_priorities),
           types: Map.get(map, "types", @valid_types),
           default_owner: Map.get(map, "default_owner"),
           extra: extra
         }}

      err ->
        err
    end
  end

  # ---- Loading ----

  def load_issue(dir_uuid, store \\ CommitStoreClient), do: load_meta(dir_uuid, @issue_file, &decode_issue/1, store)
  def load_comment(dir_uuid, filename, store \\ CommitStoreClient), do: load_meta(dir_uuid, filename, &decode_comment/1, store)
  def load_label(dir_uuid, store \\ CommitStoreClient) do
    case load_dir_schema(dir_uuid, store) do
      {:ok, schema} ->
        case Schema.get_entry(schema, "label.json") do
          {:ok, entry} ->
            case DocBuilder.reconstruct_doc(store, entry.node_id) do
              {:ok, doc} ->
                case ContentType.get_content(doc) do
                  json when is_binary(json) -> decode_label(json)
                  nil -> {:error, :empty_doc}
                end

              :none ->
                {:error, :no_doc}
            end

          :error ->
            {:error, :no_label_entry}
        end

      _ ->
        {:error, :missing}
    end
  end

  def load_meta_doc(uuid, store \\ CommitStoreClient) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} ->
        case ContentType.get_content(doc) do
          json when is_binary(json) -> decode_meta(json)
          nil -> {:error, :empty_doc}
        end

      :none ->
        {:error, :no_doc}
    end
  end

  def load_deps_doc(uuid, store \\ CommitStoreClient) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} ->
        case ContentType.get_content(doc) do
          json when is_binary(json) -> decode_deps(json)
          nil -> {:ok, []}
        end

      :none ->
        {:ok, []}
    end
  end

  @doc """
  The RAW stored bytes of `filename` in `dir_uuid`, undecoded.

  CX-xmsd uses this for the backfill's idempotency check: "already
  present with identical content" has to be decided on the stored
  bytes, not on a decoded struct, so that a re-import can never
  overwrite a comment that differs in a field the decoder drops.
  """
  @spec load_raw_text(String.t(), String.t(), term()) :: {:ok, String.t()} | {:error, term()}
  def load_raw_text(dir_uuid, filename, store \\ CommitStoreClient),
    do: load_meta(dir_uuid, filename, &{:ok, &1}, store)

  defp load_meta(dir_uuid, filename, decoder, store) do
    with {:ok, schema} <- load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, filename),
         {:ok, doc} <- DocBuilder.reconstruct_doc(store, entry.node_id),
         json when is_binary(json) <- ContentType.get_content(doc) do
      decoder.(json)
    else
      :error -> {:error, {:no_meta_entry, filename}}
      :none -> {:error, {:no_doc, filename}}
      nil -> {:error, {:empty_doc, filename}}
      other -> {:error, other}
    end
  end

  # CX-41qg.3: stable per-doc hand — callers re-commit onto the same
  # directory uuid across issue create/comment/dep writes; without a
  # fixed client_id every write minted a fresh random one.
  def load_dir_schema(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema(client_id: WriterHand.for_doc(uuid))
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        {:ok, doc}

      :none ->
        {:error, :missing}
    end
  end

  # ---- Writing ----

  # `opts[:commit_metadata]` (CX-6cz3) rides onto this doc's GENESIS
  # commit, the same way `write_text_doc/4` puts it on a chained one —
  # an import-created ticket has no chained commit to stamp, and the
  # provenance stamp / freeze pin must land on the `__issue.json`
  # chain that `Commonplace.Bd.Invariants` reads. Pulled out of `opts`
  # and passed as `create_commit/6`'s explicit metadata argument; the
  # rest of `opts` (`:signing_context`) rides through untouched.
  def create_text_doc(json, store \\ CommitStoreClient, opts \\ []) when is_binary(json) do
    {_result, uuid} = do_create_text_doc(json, store, opts)
    uuid
  end

  @doc """
  `create_text_doc/3` with the store's answer KEPT (CX-xmsd layer 1).

  Returns `{:ok, uuid}` only when the store actually accepted the
  commit, and `{:error, reason}` — notably
  `{:trust_rejected, :unsigned}` under Mode-B enforce — when it did
  not. `create_text_doc/3` discards that answer and hands back a uuid
  for a doc that may not exist; every caller that reports success to
  someone else must use this one instead.
  """
  @spec create_text_doc_checked(String.t(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_text_doc_checked(json, store \\ CommitStoreClient, opts \\ []) when is_binary(json) do
    case do_create_text_doc(json, store, opts) do
      {{:error, reason}, _uuid} -> {:error, reason}
      {_landed, uuid} -> {:ok, uuid}
    end
  end

  defp do_create_text_doc(json, store, opts) do
    uuid = UUID.uuid4()
    doc = Doc.new()
    doc = ContentType.create(doc, :text, "metadata")
    doc = if json != "", do: ContentType.insert_text(doc, 0, json), else: doc
    update = Encoding.encode_update(doc)
    metadata = Keyword.get(opts, :commit_metadata, %{})
    rest_opts = Keyword.delete(opts, :commit_metadata)
    result = CommitStoreClient.create_commit(store, uuid, update, nil, metadata, rest_opts)
    {result, uuid}
  end

  # `opts` (default `[]`) is threaded to
  # `CommitStoreClient.create_chained_commit/5` — notably
  # `:signing_context` for writes that must land as signed commits,
  # and (CX-gvbf rework) `:commit_metadata` for the caller-supplied
  # commit `metadata` map, mirroring how `ViewActionDispatch`'s
  # `do_accept_merge/7` threads `opts[:metadata]` into
  # `Tree.Merge.merge/4` for the pr-provenance stamp. Pulled out of
  # `opts` and passed as `create_chained_commit/5`'s explicit 4th
  # (metadata) argument; the REST of `opts` (signing_context etc.)
  # still rides through untouched as the 5th. Default `[]` has no
  # `:commit_metadata` key, so `Keyword.get(opts, :commit_metadata, %{})`
  # is `%{}` — byte-compatible for every existing caller, same pattern
  # as `Tree.Merge.merge/4` / `Tree.Fork.fork/2`.
  #
  # ⚠️ READ THIS BEFORE MAKING CONCURRENT MERGES OF `__issue.json`
  # CLEANER — per-field YMap storage, minimal-diff writes, or any other
  # change that replaces the delete-all/insert-all below.
  #
  # The whole-blob rewrite is currently, by ACCIDENT, the only thing
  # enforcing the post-close freeze ("a ticket closes once in v1; there
  # is no reopen path" — WriteGuard.check_frozen/2). NO merge path
  # consults WriteGuard: it has exactly two callers, ViewActionDispatch
  # and Bd.Migrate, both local write paths (CX-hk1z). So a merge can
  # compose a state WriteGuard would refuse, and nothing re-checks it.
  #
  # What stops that from becoming an observable REOPEN today is this
  # function's shape. Two divergent lines each rewrite the WHOLE blob,
  # so a merge concatenates both complete JSON documents and the doc
  # stops parsing — `Issue.show/3` returns a Jason.DecodeError (CX-o3ar,
  # runtime-verified: merge_cycle_invariant_test.exs). Loud and broken
  # beats silent and wrong.
  #
  # Make the merge cleaner and that protection is withdrawn: "closed on
  # line 1" merged with "in_progress on line 2" stops being garbage and
  # becomes a WELL-FORMED ticket with one status winning — a silent
  # reopen. The change would MANUFACTURE the bug the corruption was
  # accidentally covering, and convert a visible failure into an
  # invisible one.
  #
  # PRECONDITION: the closed-matches-pin invariant (a terminal-state
  # hash of the CANONICAL LOGICAL state written at close, not a bytes
  # CID — a bytes CID would be invalidated by the very change it must
  # survive) must exist and be checked BEFORE this write path is made
  # merge-friendly. With the pin in place the change is safe and
  # routine. Without it, it is a regression that will not announce
  # itself. See CX-o3ar and the 2026-08-05 resting-state-invariants
  # design ruling.
  def write_text_doc(uuid, json, store \\ CommitStoreClient, opts \\ [])
      when is_binary(uuid) and is_binary(json) do
    _ = do_write_text_doc(uuid, json, store, opts)
    :ok
  end

  @doc """
  `write_text_doc/4` with the store's answer KEPT (CX-xmsd layer 1).

  `write_text_doc/4` returns a bare `:ok` whatever the store said, so a
  denied edit is indistinguishable from a landed one. This returns
  `:ok` only when the chained commit was accepted.
  """
  @spec write_text_doc_checked(String.t(), String.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def write_text_doc_checked(uuid, json, store \\ CommitStoreClient, opts \\ [])
      when is_binary(uuid) and is_binary(json) do
    case do_write_text_doc(uuid, json, store, opts) do
      {:error, reason} -> {:error, reason}
      _landed -> :ok
    end
  end

  defp do_write_text_doc(uuid, json, store, opts) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid, client_id: WriterHand.for_doc(uuid))
    current = ContentType.get_content(doc) || ""
    doc = if current != "", do: ContentType.delete_text(doc, 0, String.length(current)), else: doc
    doc = if json != "", do: ContentType.insert_text(doc, 0, json), else: doc
    update = Encoding.encode_update(doc)
    metadata = Keyword.get(opts, :commit_metadata, %{})
    rest_opts = Keyword.delete(opts, :commit_metadata)
    CommitStoreClient.create_chained_commit(store, uuid, update, metadata, rest_opts)
  end

  def create_dir_with_meta(meta_filename, json, store \\ CommitStoreClient, opts \\ []) do
    case do_create_dir_with_meta(meta_filename, json, store, opts) do
      {{:error, reason}, _dir_uuid} -> {:error, reason}
      {_landed, dir_uuid} -> dir_uuid
    end
  end

  @doc "`create_dir_with_meta/4` with the store's answer kept."
  @spec create_dir_with_meta_checked(String.t() | nil, String.t() | nil, term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_dir_with_meta_checked(meta_filename, json, store \\ CommitStoreClient, opts \\ []) do
    case do_create_dir_with_meta(meta_filename, json, store, opts) do
      {{:error, reason}, _uuid} -> {:error, reason}
      {_landed, uuid} -> {:ok, uuid}
    end
  end

  defp do_create_dir_with_meta(meta_filename, json, store, opts) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()

    meta_result =
      if json do
        create_text_doc_checked(json, store, opts)
      else
        {:ok, nil}
      end

    case meta_result do
      {:ok, nil} ->
        update = Encoding.encode_update(dir_doc)
        result = CommitStoreClient.create_commit(store, dir_uuid, update, nil, %{}, opts)
        {result, dir_uuid}

      {:ok, meta_uuid} ->
        dir_doc = Schema.add_file(dir_doc, meta_filename, meta_uuid)
        update = Encoding.encode_update(dir_doc)
        result = CommitStoreClient.create_commit(store, dir_uuid, update, nil, %{}, opts)
        {result, dir_uuid}

      {:error, reason} ->
        {{:error, reason}, dir_uuid}
    end
  end
end
