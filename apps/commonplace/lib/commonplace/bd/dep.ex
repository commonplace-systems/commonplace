defmodule Commonplace.Bd.Dep do
  @moduledoc """
  Dependency edges in /bd/deps.json.

  Spec: §2.3 (one-doc-per-graph rationale) and §5.4 (LWW-on-key
  semantics for add/remove with no tombstone-undo).

  P1: edges live in a JSON-encoded text doc as a flat
  `%{edge_key => edge_value}` map. Read-modify-write under the hood
  for now; per-key YMap semantics are exact-spec for the substrate
  and a P3 lift to true YMap content. The §5.4 LWW fixture is still
  testable in P1 by exercising sequential vs concurrent writes
  through the same store.
  """

  alias Commonplace.Bd.{Schemas, Workspace}
  alias Commonplace.Bd.Schemas.Edge
  alias Commonplace.Store.CommitStoreClient

  @doc """
  Adds an edge from `from_id` to `to_id` of the given `kind`.
  Idempotent — adding the same edge twice has no observable effect
  beyond the LWW-tiebroken `created_at` metadata.
  """
  def add(root_uuid, from_id, to_id, kind \\ "blocks", attrs \\ %{}, store \\ CommitStoreClient) do
    edge = %Edge{
      from: from_id,
      to: to_id,
      kind: kind,
      created_at: Map.get(attrs, :created_at, now_iso8601()),
      created_by: Map.get(attrs, :created_by)
    }

    with {:ok, deps_uuid} <- Workspace.deps_uuid(root_uuid, store),
         {:ok, edges} <- Schemas.load_deps_doc(deps_uuid, store) do
      key = Edge.key(edge)
      filtered = Enum.reject(edges, fn e -> Edge.key(e) == key end)
      new_edges = filtered ++ [edge]

      Schemas.write_text_doc(deps_uuid, Schemas.encode_deps(new_edges), store)
      {:ok, edge}
    end
  end

  @doc """
  Removes the edge from `from_id` to `to_id` of `kind`. No-op if the
  edge is absent.
  """
  def remove(root_uuid, from_id, to_id, kind \\ "blocks", store \\ CommitStoreClient) do
    with {:ok, deps_uuid} <- Workspace.deps_uuid(root_uuid, store),
         {:ok, edges} <- Schemas.load_deps_doc(deps_uuid, store) do
      key = Edge.key(from_id, to_id, kind)
      new_edges = Enum.reject(edges, fn e -> Edge.key(e) == key end)

      Schemas.write_text_doc(deps_uuid, Schemas.encode_deps(new_edges), store)
      :ok
    end
  end

  @doc "Lists every edge in the dependency graph."
  def list(root_uuid, store \\ CommitStoreClient) do
    with {:ok, deps_uuid} <- Workspace.deps_uuid(root_uuid, store),
         {:ok, edges} <- Schemas.load_deps_doc(deps_uuid, store) do
      edges
    else
      _ -> []
    end
  end

  @doc "Returns edges where `to == id` — i.e. things that block `id`."
  def incoming(root_uuid, id, kind \\ "blocks", store \\ CommitStoreClient) do
    list(root_uuid, store) |> Enum.filter(fn e -> e.to == id and e.kind == kind end)
  end

  @doc "Returns edges where `from == id` — i.e. things `id` blocks."
  def outgoing(root_uuid, id, kind \\ "blocks", store \\ CommitStoreClient) do
    list(root_uuid, store) |> Enum.filter(fn e -> e.from == id and e.kind == kind end)
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
