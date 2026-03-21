defmodule Commonplace.Tree.Walk do
  @moduledoc """
  Walk the document tree by resolving paths across schema docs.

  Paths like "repos/myrepo/main/notes.txt" are resolved by loading
  schema docs at each directory level and following node_id references.

  The `loader` argument is a function `(uuid) -> Yelixer.Doc` that
  loads a schema doc by its UUID. This keeps the walk logic decoupled
  from storage — the caller provides the loading strategy.
  """

  alias Commonplace.Tree.Schema

  @doc """
  Resolve a path to a UUID, starting from root_uuid.

  The loader function `(uuid) -> doc` loads a schema doc by UUID.

  Returns `{:ok, uuid}` or `{:error, reason}`.
  """
  def resolve_path(root_uuid, "", _loader), do: {:ok, root_uuid}

  def resolve_path(root_uuid, path, loader) when is_binary(path) do
    segments = String.split(path, "/", trim: true)
    walk_segments(root_uuid, segments, loader)
  end

  @doc """
  List children at a path, starting from root_uuid.

  Returns `{:ok, [Schema.Entry.t()]}` or `{:error, reason}`.
  """
  def list_path(root_uuid, "", loader) do
    doc = loader.(root_uuid)
    {:ok, Schema.list_entries(doc)}
  end

  def list_path(root_uuid, path, loader) when is_binary(path) do
    case resolve_path(root_uuid, path, loader) do
      {:ok, dir_uuid} ->
        doc = loader.(dir_uuid)
        {:ok, Schema.list_entries(doc)}

      error ->
        error
    end
  end

  @doc """
  Collect all UUIDs reachable from root by walking the tree recursively.

  Returns a MapSet of all reachable UUIDs (including root).
  """
  def reachable_uuids(root_uuid, loader) do
    collect_reachable(root_uuid, loader, MapSet.new())
  end

  # --- Private ---

  defp walk_segments(current_uuid, [], _loader), do: {:ok, current_uuid}

  defp walk_segments(current_uuid, [segment | rest], loader) do
    doc = loader.(current_uuid)

    case Schema.get_entry(doc, segment) do
      {:ok, entry} ->
        if rest == [] do
          # Last segment — return the node_id regardless of type
          {:ok, entry.node_id}
        else
          # More segments to go — must be a directory
          case entry.type do
            :dir ->
              walk_segments(entry.node_id, rest, loader)

            _ ->
              {:error, {:not_a_directory, segment}}
          end
        end

      :error ->
        {:error, {:not_found, segment}}
    end
  end

  defp safe_load(uuid, loader) do
    try do
      {:ok, loader.(uuid)}
    rescue
      _ -> :error
    end
  end

  defp collect_reachable(uuid, loader, visited) do
    if MapSet.member?(visited, uuid) do
      visited
    else
      visited = MapSet.put(visited, uuid)

      case safe_load(uuid, loader) do
        {:ok, doc} ->
          Schema.list_entries(doc)
          |> Enum.reduce(visited, fn entry, acc ->
            if entry.type == :dir do
              collect_reachable(entry.node_id, loader, acc)
            else
              MapSet.put(acc, entry.node_id)
            end
          end)

        :error ->
          # Leaf doc or load failure — just return visited
          visited
      end
    end
  end
end
