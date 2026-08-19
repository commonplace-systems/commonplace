defmodule Commonplace.Store.Commit do
  @moduledoc """
  One node in the commit DAG: a content-addressed record of a single
  change to one document.

  Every Commonplace document is a Y.js CRDT, and its history is a chain
  of commits. Each commit holds a Yjs **update delta** (the binary that
  advances a doc from its parent's state to this one) plus a pointer to
  that parent. Replaying a doc means walking the chain from the root and
  applying each delta — `Commonplace.Tree.DocBuilder` does the walking;
  this module is the immutable value it walks over.

  ## Content-addressing: the id *is* the hash

  A commit's `id` is the SHA-256 of its own load-bearing fields — not a
  random UUID. Two consequences flow from that:

    1. **Tamper-evidence.** Altering a commit's parent, delta, or replay
       semantics changes its id. A receiver re-hashes (`verify_id/1`)
       and rejects any commit whose claimed id doesn't match its content.
       The DAG is Merkle (each node's hash covers its full ancestry via
       `parent_id`).
    2. **Convergent ids.** Two nodes that independently produce the same
       change compute the same id, so the store deduplicates them for
       free and a doc re-created from the same inputs lands on the same
       history. `genesis/1` exploits this deliberately (below).

  Every field that changes what a commit *means* must fold into the
  hash. The rest of this doc catalogues which fields those are and the
  backward-compatibility hatch that keeps old ids stable.

  ## What binds into the id, and the legacy hatch

  The content-address formula (`content_address/4`) is:

      sha256((parent_id || <<>>) <> update
               <> canonical_metadata(metadata)
               <> canonical_merge_parents(merge_parents))

  `parent_id` and `update` have always been hashed. The two later
  additions — `metadata` and `merge_parents` — each carry a
  **legacy hatch**: when they hold their default empty value
  (`%{}` / `[]`), `canonical_*` returns the empty binary, collapsing
  the formula to the original `sha256(parent_id <> update)`. This keeps
  historical commit ids byte-for-byte stable. Non-empty values
  serialize deterministically (`:erlang.term_to_binary/2` with
  `:deterministic`) and bind into the hash, so new metadata kinds apply
  to new writes without renaming old commits.

  Just as load-bearing is what stays *out* of the hash. Four struct
  fields are deliberately excluded: `timestamp` (wall-clock, stamped at
  construction), `doc_uuid` (a debugging trace of which uuid first wrote
  the commit), and `signature`/`signer_id` (added later, and themselves
  a signature *over* the id). None change what the commit means, so
  leaving them out is exactly what lets `genesis/1` converge on one id
  across independent re-creations even though each call stamps a
  different `timestamp`.

  ### `metadata` — replay semantics that MUST be hashed

  `metadata` is a map of free-form annotations whose `:kind` tag
  declares replay semantics — `:snapshot`, `:merge`, `:genesis`, future
  kinds. `:snapshot` *changes how readers replay the chain* (see
  `Commonplace.Tree.DocBuilder.reconstruct_doc/2` and
  `Commonplace.Document.Server.handle_info/2`): it tells a reader it may
  discard pre-snapshot history. That power is why metadata must bind
  into the id. Without it, a hostile peer could retag an ordinary delta
  as `%{kind: :snapshot}` without changing its id, causing readers to
  silently drop earlier history — or treat a real snapshot as a plain
  delta (CX-u7p round-2).

  Non-empty metadata MUST include a `:kind` key; `new/5` rejects
  kindless non-empty metadata at create time (`validate_metadata_kind!/1`).
  The empty-metadata hatch stays open only for pre-CX-bv3 delta commits
  that carried no metadata.

  Metadata may also carry kind-specific keys beyond `:kind`. `genesis/1`
  stores `%{kind: :genesis, doc_uuid: doc_uuid}`, and because metadata
  binds into the hash, folding `doc_uuid` in here is exactly what makes a
  genesis id a pure function of the uuid. Such extra keys *describe* the
  commit; they don't introduce new replay rules — that stays the `:kind`
  tag's job.

  ### `merge_parents` — extra DAG edges that MUST be hashed

  A merge commit has more than one parent. `parent_id` names the
  primary line; `merge_parents` lists additional parent ids (CX-bv3).
  These change the commit's position in the DAG, so they bind into the
  id. **Order matters** — `[a, b]` and `[b, a]` hash to different ids —
  so callers must provide merge parents in a stable order; the merge
  code that builds the commit owns that ordering.

  ## Signing happens downstream — on the id

  `signature` and `signer_id` (an identifier of the signing key) are
  populated after construction by `Commonplace.Store.CommitStore` via
  `maybe_sign_commit/2`, which signs `commit.id` with the session's
  Ed25519 key (see `Commonplace.Crypto.Signing.sign_commit/3`). This
  module mints the id;
  it never signs. Because the id covers every meaningful field, a
  signature over the id is transitively a signature over the full
  commit. Both fields are `nil` on unsigned commits.

  ## Public surface

    - `new/5` — mint a regular commit: validate metadata, stamp the
      time, compute the id. The everyday constructor, called by
      `CommitStore` on the write path.
    - `genesis/1` — the deterministic synthetic first commit of a doc,
      whose id is a pure function of `doc_uuid` (see its `@doc`).
      Exploits convergent ids so re-creating a doc lands on the same
      root.
    - `verify_id/1` — re-hash and compare to the claimed id. The trust
      gate `import_commit` runs before anything else reads the commit's
      fields.

  ## Worked example

      # the synthetic root of doc "d" — id is a pure function of "d"
      g = Commit.genesis("d")
      Commit.genesis("d").id == g.id   # true, even on another node at
      #   another time: same uuid ⇒ same id (timestamp differs but
      #   isn't hashed) — this is the convergent-ids property

      # node A authors a change to doc "d"
      c1 = Commit.new("d", update_bytes, nil)
      #   c1.parent_id == nil, c1.id == sha256(<<>> <> update_bytes)

      # a child builds on it
      c2 = Commit.new("d", more_bytes, c1.id)
      #   c2.id == sha256(c1.id <> more_bytes)
      #   c2's id transitively commits to c1 (Merkle chain)

      # a peer ships us c2; we re-hash before trusting any field
      :ok = Commit.verify_id(c2)
      # had the peer flipped c2.parent_id or retagged it a snapshot,
      # verify_id would return {:error, {:id_mismatch, _, _}}

  ## Invariants

    - **`id == content_address(update, parent_id, metadata, merge_parents)`**
      for every well-formed commit. `verify_id/1` is the check.
    - **Empty `metadata`/`merge_parents` reproduce the original
      `sha256(parent_id <> update)`** — historical ids never move.
    - **Non-empty `metadata` carries a `:kind`** — enforced at
      `new/5`; `genesis/1` tags `:genesis`.
    - **`genesis(doc_uuid)` is deterministic** — same uuid ⇒ same id,
      across independent re-creations.
    - **Signing is over the id, not the fields** — done downstream, so
      it inherits the id's coverage of every meaningful field.

  ## What this module is NOT

  - **Not the store.** Persistence, the `:latest` pointer, chaining,
    and signing live in `Commonplace.Store.CommitStore` /
    `CommitStoreClient`. This module is the value object they persist.
  - **Not the replayer.** Turning a chain of deltas back into a live
    doc is `Commonplace.Tree.DocBuilder`'s job.
  - **Not the signer.** It defines the `signature`/`signer_id` fields;
    `Commonplace.Crypto.Signing` fills them.
  - **Not the namespace validator.** `verify_id/1` proves a commit is
    self-consistent; whether it is *allowed* in a given namespace is a
    downstream check (see CX-gwz: id gate first, validator second).
  """

  defstruct [
    :id,
    # Historical: which UUID originally created this commit (debugging only)
    :doc_uuid,
    :parent_id,
    :update,
    :timestamp,
    # Ed25519 signature of commit.id, or nil if unsigned
    :signature,
    # identifier of the signing key, or nil if unsigned
    :signer_id,
    # {encoding_version, hash} of the state the WRITER produced, or nil (legacy-compatible mint sites); binds into id when present (CX-6scm)
    :post_state_hash,
    # free-form annotations (e.g. %{kind: :snapshot}); non-empty requires :kind and binds into id (CX-u7p r2, CX-bv3)
    metadata: %{},
    # additional parent commit ids for merge commits; binds into id when non-empty (CX-bv3)
    merge_parents: []
  ]

  @typedoc """
  `{encoding_version, hash}` — never a bare hash.

  See `Commonplace.Projection.PostState` for the version constant and the
  76dcd3c lesson it encodes.
  """
  @type post_state_hash :: {non_neg_integer(), binary()} | nil

  @type t :: %__MODULE__{
          id: binary(),
          doc_uuid: String.t(),
          parent_id: binary() | nil,
          update: binary(),
          timestamp: DateTime.t(),
          signature: binary() | nil,
          signer_id: String.t() | nil,
          post_state_hash: post_state_hash(),
          metadata: map(),
          merge_parents: [binary()]
        }

  def new(
        doc_uuid,
        update,
        parent_id \\ nil,
        metadata \\ %{},
        merge_parents \\ [],
        post_state_hash \\ nil
      ) do
    validate_metadata_kind!(metadata)
    validate_post_state_hash!(post_state_hash)
    timestamp = DateTime.utc_now()
    id = content_address(update, parent_id, metadata, merge_parents, post_state_hash)

    %__MODULE__{
      id: id,
      doc_uuid: doc_uuid,
      parent_id: parent_id,
      update: update,
      timestamp: timestamp,
      metadata: metadata,
      merge_parents: merge_parents,
      post_state_hash: post_state_hash
    }
  end

  @doc """
  Build the deterministic genesis commit for `doc_uuid` (CX-fzi).

  Genesis is the synthetic first commit of every post-umbrella doc. It
  establishes the namespace root from which regular commits and
  snapshots descend. The hash is a pure function of `doc_uuid`, so two
  independent creations of a doc with the same uuid converge on the
  same genesis id — the property that lets "the first real user edit
  is a regular commit with `snapshot_parent = genesis.id`" hold
  robustly across re-creation. See docs/namespace-model.md § Genesis
  (commonplace-plan).
  """
  def genesis(doc_uuid) do
    metadata = %{kind: :genesis, doc_uuid: doc_uuid}
    id = content_address(<<>>, nil, metadata, [], nil)

    %__MODULE__{
      id: id,
      doc_uuid: doc_uuid,
      parent_id: nil,
      update: <<>>,
      timestamp: DateTime.utc_now(),
      metadata: metadata,
      merge_parents: []
    }
  end

  @doc """
  Recompute a commit's content address and compare to its claimed `id`.

  Returns `:ok` when they match, `{:error, {:id_mismatch, computed,
  claimed}}` otherwise.

  `import_commit` uses this as a gate BEFORE the namespace validator:
  nothing about the commit's fields (including those the validator
  reads) is trustworthy until the id matches the content hash. Without
  this gate a hostile peer can retag an ordinary delta as
  `%{kind: :snapshot}` and drive `DocBuilder.reconstruct_doc/2` to
  skip earlier history, or flip `parent_id`/`update`/`merge_parents`
  to forge the DAG. See CX-gwz.
  """
  @spec verify_id(t()) :: :ok | {:error, {:id_mismatch, binary(), binary()}}
  def verify_id(%__MODULE__{} = commit) do
    computed = content_address_of(commit)

    if computed == commit.id do
      :ok
    else
      {:error, {:id_mismatch, computed, commit.id}}
    end
  end

  @doc """
  Recompute a commit's content address from the fields PRESENT on the
  struct, without comparing it to the claimed `id`.

  `Commonplace.Projection` needs the raw recomputation (not `verify_id/1`'s
  boolean) so it can verify a signature against the address the bytes
  ACTUALLY hash to, rather than against the id the commit merely claims
  (CX-6scm). Tampered `update` bytes on a signed commit therefore fail
  loudly instead of being absorbed.
  """
  @spec content_address_of(t()) :: binary()
  def content_address_of(%__MODULE__{} = commit) do
    content_address(
      commit.update,
      commit.parent_id,
      commit.metadata,
      commit.merge_parents,
      post_state_hash(commit)
    )
  end

  @doc """
  Read a commit's carried post-state hash, **legacy-row safe**.

  Adding a struct field is a MIGRATION here, because the store holds
  `:erlang.term_to_binary/1` of `%Commit{}`. A row written before
  `:post_state_hash` existed round-trips back as a map that does not
  have the key at all: `commit.post_state_hash` raises `KeyError`, and
  `%Commit{post_state_hash: _} = row` does not match. There are 64,651
  such rows on the live serve and every one of them is read by
  `Commonplace.Projection`, so a direct field read is a crash on the
  first legacy commit touched — measured, not theorised
  (`test/commonplace/projection/legacy_row_shape_test.exs`).

  Every reader of this field must go through here. A legacy row and a
  modern row with an explicit `nil` are the same commit, and the
  `nil -> <<>>` hatch in `content_address/5` keeps their ids identical.
  """
  @spec post_state_hash(t()) :: post_state_hash()
  def post_state_hash(%__MODULE__{} = commit), do: Map.get(commit, :post_state_hash)

  # Content-address formula (CX-u7p r2, extended CX-bv3, extended CX-6scm):
  #   sha256((parent_id || <<>>) <> update <> canonical_metadata(metadata)
  #            <> canonical_merge_parents(merge_parents)
  #            <> canonical_post_state_hash(post_state_hash))
  #
  # `canonical_metadata(%{})`, `canonical_merge_parents([])` and
  # `canonical_post_state_hash(nil)` are all the empty binary so
  # historical commits that were written without any of them keep their
  # original id. Non-empty values are serialized deterministically via
  # `:erlang.term_to_binary/2` with `:deterministic`.
  #
  # CX-6scm: `post_state_hash` MUST bind into the id. The whole point of
  # the witnessed grade is that the writer's own expectation is carried
  # under the signature — and the signature is over the id, so a field
  # outside the id would be freely editable by any holder of the row and
  # the "witness" would witness nothing.
  defp content_address(update, parent_id, metadata, merge_parents, post_state_hash) do
    data =
      (parent_id || <<>>) <>
        update <>
        canonical_metadata(metadata) <>
        canonical_merge_parents(merge_parents) <>
        canonical_post_state_hash(post_state_hash)

    :crypto.hash(:sha256, data)
  end

  defp canonical_post_state_hash(nil), do: <<>>

  defp canonical_post_state_hash({version, hash}) when is_integer(version) and is_binary(hash) do
    :erlang.term_to_binary({version, hash}, [:deterministic])
  end

  defp validate_post_state_hash!(nil), do: :ok

  defp validate_post_state_hash!({version, hash}) when is_integer(version) and is_binary(hash),
    do: :ok

  defp validate_post_state_hash!(other) do
    raise ArgumentError,
          "post_state_hash must be nil or {encoding_version, hash} — never a bare hash " <>
            "(got #{inspect(other)})"
  end

  defp canonical_metadata(metadata) when metadata == %{}, do: <<>>

  defp canonical_metadata(metadata) when is_map(metadata) do
    :erlang.term_to_binary(metadata, [:deterministic])
  end

  defp canonical_merge_parents([]), do: <<>>

  defp canonical_merge_parents(merge_parents) when is_list(merge_parents) do
    :erlang.term_to_binary(merge_parents, [:deterministic])
  end

  defp validate_metadata_kind!(metadata) when metadata == %{}, do: :ok

  defp validate_metadata_kind!(metadata) when is_map(metadata) do
    if Map.has_key?(metadata, :kind) do
      :ok
    else
      raise ArgumentError,
            "commit metadata must include a :kind tag when non-empty (got #{inspect(metadata)})"
    end
  end
end
