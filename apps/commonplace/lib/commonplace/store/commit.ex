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
  """

  defstruct [
    :id,
    :doc_uuid,    # Historical: which UUID originally created this commit (debugging only)
    :parent_id,
    :update,
    :timestamp,
    :signature,   # Ed25519 signature of commit.id, or nil if unsigned
    :signer_id,   # identifier of the signing key, or nil if unsigned
    metadata: %{} # free-form annotations (e.g. %{kind: :snapshot}); bound into content address when non-empty (CX-u7p r2)
  ]

  @type t :: %__MODULE__{
          id: binary(),
          doc_uuid: String.t(),
          parent_id: binary() | nil,
          update: binary(),
          timestamp: DateTime.t(),
          signature: binary() | nil,
          signer_id: String.t() | nil,
          metadata: map()
        }

  def new(doc_uuid, update, parent_id \\ nil, metadata \\ %{}) do
    timestamp = DateTime.utc_now()
    id = content_address(update, parent_id, metadata)

    %__MODULE__{
      id: id,
      doc_uuid: doc_uuid,
      parent_id: parent_id,
      update: update,
      timestamp: timestamp,
      metadata: metadata
    }
  end

  # Content-address formula (CX-u7p r2):
  #   sha256((parent_id || <<>>) <> update <> canonical_metadata(metadata))
  #
  # `canonical_metadata(%{})` is the empty binary so historical commits
  # that were written with no metadata keep their original id (preserves
  # existing test fixtures, CubDB contents, and signed commits). Non-
  # empty metadata is serialized deterministically via
  # `:erlang.term_to_binary/2` with `:deterministic` so the same map
  # always hashes to the same bytes across BEAM runs and nodes.
  defp content_address(update, parent_id, metadata) do
    data = (parent_id || <<>>) <> update <> canonical_metadata(metadata)
    :crypto.hash(:sha256, data)
  end

  defp canonical_metadata(metadata) when metadata == %{}, do: <<>>

  defp canonical_metadata(metadata) when is_map(metadata) do
    :erlang.term_to_binary(metadata, [:deterministic])
  end
end
