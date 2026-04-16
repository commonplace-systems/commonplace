defmodule Commonplace.Store.Commit do
  @moduledoc """
  A content-addressed commit in the Merkle DAG.

  Each commit stores a Yjs update delta and references its parent,
  forming a tamper-evident history chain.

  The `metadata` field is a map of free-form annotations (e.g.
  `%{kind: :snapshot}` for compaction snapshots). Metadata is NOT
  factored into `id` so backward-compatible readers and the same commit
  payload (parent + update) round-trip to the same content address. New
  metadata kinds added later cannot retroactively change historical
  commit IDs.
  """

  defstruct [
    :id,
    :doc_uuid,    # Historical: which UUID originally created this commit (debugging only)
    :parent_id,
    :update,
    :timestamp,
    :signature,   # Ed25519 signature of commit.id, or nil if unsigned
    :signer_id,   # identifier of the signing key, or nil if unsigned
    metadata: %{} # free-form annotations (e.g. %{kind: :snapshot}); not in content address
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
    id = content_address(update, parent_id)

    %__MODULE__{
      id: id,
      doc_uuid: doc_uuid,
      parent_id: parent_id,
      update: update,
      timestamp: timestamp,
      metadata: metadata
    }
  end

  defp content_address(update, parent_id) do
    data = (parent_id || <<>>) <> update
    :crypto.hash(:sha256, data)
  end
end
