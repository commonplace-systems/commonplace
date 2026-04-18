defmodule Commonplace.Store.Commit do
  @moduledoc """
  A content-addressed commit in the Merkle DAG.

  Each commit stores a Yjs update delta and references its parent,
  forming a tamper-evident history chain.

  The `metadata` field is a map of free-form annotations (e.g.
  `%{kind: :snapshot}` for compaction snapshots). Because metadata
  kinds like `:snapshot` CHANGE replay semantics (see
  `Commonplace.Tree.DocBuilder.reconstruct_doc/2` and
  `Commonplace.Document.Server.handle_info/2`), metadata MUST be
  bound into the content address — otherwise a peer could retag an
  existing commit as a snapshot without changing its id, causing
  readers to silently discard pre-snapshot history or treat a real
  snapshot as a normal delta (CX-u7p round-2).

  To preserve backward compatibility with historical commits that were
  hashed with no metadata, the empty-metadata case (`%{}`) still hashes
  as `sha256(parent_id || <<>> <> update)` — the original formula. Only
  non-empty metadata maps are folded into the hash. New metadata kinds
  added later therefore bind into the id for new writes without
  retroactively changing the ids of historical metadata-free commits.

  The `merge_parents` field lists additional parent commit ids for
  merge commits (CX-bv3). Like metadata, merge_parents CHANGES the
  commit's position in the DAG and so MUST bind into the content
  address. Empty-list (`[]`, the default) preserves the legacy hash;
  non-empty merge_parents serialize deterministically and bind into
  the id. Order matters — `[a, b]` and `[b, a]` hash differently.

  When `metadata` is non-empty it MUST include a `:kind` key. The
  `:kind` tag declares the commit's replay semantics (`:snapshot`,
  `:merge`, future kinds). Non-empty metadata without a kind is
  rejected at create time so that every semantically-distinct commit
  self-describes via a known tag. The empty-metadata legacy hatch
  remains available for pre-CX-bv3 delta commits that were hashed
  without any metadata at all.
  """

  defstruct [
    :id,
    :doc_uuid,    # Historical: which UUID originally created this commit (debugging only)
    :parent_id,
    :update,
    :timestamp,
    :signature,   # Ed25519 signature of commit.id, or nil if unsigned
    :signer_id,   # identifier of the signing key, or nil if unsigned
    metadata: %{},      # free-form annotations (e.g. %{kind: :snapshot}); non-empty requires :kind and binds into id (CX-u7p r2, CX-bv3)
    merge_parents: []   # additional parent commit ids for merge commits; binds into id when non-empty (CX-bv3)
  ]

  @type t :: %__MODULE__{
          id: binary(),
          doc_uuid: String.t(),
          parent_id: binary() | nil,
          update: binary(),
          timestamp: DateTime.t(),
          signature: binary() | nil,
          signer_id: String.t() | nil,
          metadata: map(),
          merge_parents: [binary()]
        }

  def new(doc_uuid, update, parent_id \\ nil, metadata \\ %{}, merge_parents \\ []) do
    validate_metadata_kind!(metadata)
    timestamp = DateTime.utc_now()
    id = content_address(update, parent_id, metadata, merge_parents)

    %__MODULE__{
      id: id,
      doc_uuid: doc_uuid,
      parent_id: parent_id,
      update: update,
      timestamp: timestamp,
      metadata: metadata,
      merge_parents: merge_parents
    }
  end

  # Content-address formula (CX-u7p r2, extended CX-bv3):
  #   sha256((parent_id || <<>>) <> update <> canonical_metadata(metadata) <> canonical_merge_parents(merge_parents))
  #
  # `canonical_metadata(%{})` and `canonical_merge_parents([])` are
  # both the empty binary so historical commits that were written
  # without either keep their original id. Non-empty values are
  # serialized deterministically via `:erlang.term_to_binary/2` with
  # `:deterministic`.
  defp content_address(update, parent_id, metadata, merge_parents) do
    data =
      (parent_id || <<>>) <>
        update <>
        canonical_metadata(metadata) <>
        canonical_merge_parents(merge_parents)

    :crypto.hash(:sha256, data)
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
