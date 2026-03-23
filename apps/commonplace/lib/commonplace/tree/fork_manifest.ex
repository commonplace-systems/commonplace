defmodule Commonplace.Tree.ForkManifest do
  @moduledoc """
  Tracks the relationship between a forked directory subtree and its source.

  Every document in the forked subtree gets an entry in `document_map`,
  mapping the new UUID to the original UUID and fork-point commit.
  """

  defstruct [:id, :forked_from, :forked_at, document_map: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          forked_from: String.t(),
          forked_at: DateTime.t(),
          document_map: %{String.t() => fork_entry()}
        }

  @type fork_entry :: %{
          original_uuid: String.t(),
          fork_point_commit: binary()
        }

  def new(forked_from) do
    %__MODULE__{
      id: UUID.uuid4(),
      forked_from: forked_from,
      forked_at: DateTime.utc_now(),
      document_map: %{}
    }
  end

  def add_entry(manifest, new_uuid, original_uuid, fork_point_commit) do
    entry = %{original_uuid: original_uuid, fork_point_commit: fork_point_commit}
    %{manifest | document_map: Map.put(manifest.document_map, new_uuid, entry)}
  end

  def to_map(manifest) do
    %{
      "id" => manifest.id,
      "forked_from" => manifest.forked_from,
      "forked_at" => DateTime.to_iso8601(manifest.forked_at),
      "document_map" =>
        Map.new(manifest.document_map, fn {uuid, entry} ->
          {uuid,
           %{
             "original_uuid" => entry.original_uuid,
             "fork_point_commit" => Base.encode16(entry.fork_point_commit, case: :lower)
           }}
        end)
    }
  end
end
