defmodule Commonplace.Store.Commit do
  @moduledoc """
  A content-addressed commit in the Merkle DAG.

  Each commit stores a Yjs update delta and references its parent,
  forming a tamper-evident history chain.
  """

  defstruct [:id, :doc_uuid, :parent_id, :update, :timestamp]

  @type t :: %__MODULE__{
          id: binary(),
          doc_uuid: String.t(),
          parent_id: binary() | nil,
          update: binary(),
          timestamp: DateTime.t()
        }

  def new(doc_uuid, update, parent_id \\ nil) do
    timestamp = DateTime.utc_now()
    id = content_address(update, parent_id)

    %__MODULE__{
      id: id,
      doc_uuid: doc_uuid,
      parent_id: parent_id,
      update: update,
      timestamp: timestamp
    }
  end

  defp content_address(update, parent_id) do
    data = (parent_id || <<>>) <> update
    :crypto.hash(:sha256, data)
  end
end
