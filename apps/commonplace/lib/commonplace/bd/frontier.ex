defmodule Commonplace.Bd.Frontier do
  @moduledoc """
  `needs`-based ready/blocked walk oracle — Bd P2 Slice S2.

  This is the from-scratch computation `Frontier.Server` (the
  reactive maintainer) is checked against; it never trusts anything
  cached. Cost is O(issues + edges), same order as `Bd.Ready`.

  ## Relationship to `Bd.Ready` (P1)

  `Bd.Ready` walks `blocks` edges in `/bd/deps.json`. This module
  walks `needs` refs embedded in each issue's own `__issue.json`
  (see `Commonplace.Bd.Schemas.Issue.needs`). They are DIFFERENT
  graphs over the same tickets and are NOT reconciled here — `Ready`
  and `Dep` are left untouched per the S2 brief; this module is
  additive.

  ## Semantics

  An issue is READY iff:

    * its `status` is `"open"`, AND
    * every entry in its `needs` list resolves to a LOCAL ticket
      whose `status` is in `["closed", "wontfix"]`.

  Otherwise it is BLOCKED (if `status == "open"`) or simply not part
  of either set (if not open).

  **The §2 inversion** (this is the load-bearing difference from
  `Bd.Ready`'s unknown-blocker-is-satisfied default): an
  UNRESOLVABLE `needs` entry counts as UNSATISFIED, so the dependent
  is BLOCKED, not ready. Unresolvable means either:

    * the entry carries a `"repo"` key (cross-repo — no local
      replica exists in this arc, so it cannot be verified), or
    * the entry's local `"ticket"` id does not resolve to any
      existing issue.

  "Can't become ready on information you can't see" — the opposite
  of `Bd.Ready`'s stance, where an unknown blocker is treated as
  already resolved.

  Diamond dedup is free: two paths needing the same ticket share one
  entry in the id→status map, so the shared prereq is evaluated once.

  ## Query definition (plain data, not a DSL)

  Kept as module attributes so a future generic standing-query
  engine could read them off this module rather than reimplementing
  the walk:

    * `scope` — `"/bd/issues/**"` (every issue under `/bd/issues/`)
    * `satisfied_statuses` — `["closed", "wontfix"]`
    * `edge_field` — `:needs`
  """

  alias Commonplace.Bd.Issue
  alias Commonplace.Bd.Schemas.Issue, as: IssueStruct
  alias Commonplace.Bd.Workspace
  alias Commonplace.Green.BursarClient
  alias Commonplace.Store.CommitStoreClient

  @scope "/bd/issues/**"
  @satisfied_statuses ~w(closed wontfix)
  @edge_field :needs

  def scope, do: @scope
  def satisfied_statuses, do: @satisfied_statuses
  def edge_field, do: @edge_field

  @doc """
  The single recompute the reactive server uses. Returns
  `%{ready: MapSet.t(String.t()), blocked: MapSet.t(String.t())}` of
  issue ids.
  """
  def compute(root_uuid, store \\ CommitStoreClient) do
    issues_by_id = load_issues_by_id(root_uuid, store)
    {ready_ids, blocked_ids} = partition(issues_by_id)
    %{ready: MapSet.new(ready_ids), blocked: MapSet.new(blocked_ids)}
  end

  @doc "Open issues whose `needs` are all satisfied, sorted by id."
  def ready_walk(root_uuid, store \\ CommitStoreClient) do
    issues_by_id = load_issues_by_id(root_uuid, store)
    {ready_ids, _blocked_ids} = partition(issues_by_id)
    to_sorted_issues(ready_ids, issues_by_id)
  end

  @doc "Open issues with at least one unsatisfied `needs` entry, sorted by id."
  def blocked_walk(root_uuid, store \\ CommitStoreClient) do
    issues_by_id = load_issues_by_id(root_uuid, store)
    {_ready_ids, blocked_ids} = partition(issues_by_id)
    to_sorted_issues(blocked_ids, issues_by_id)
  end

  @doc """
  Bd P2 Slice S4 — the READY set minus tickets whose custody token is
  currently HELD. Two axes, deliberately not conflated: `compute/2` /
  `ready_walk/2` above answer readiness (status + `needs`, the S2
  frontier); this answers "ready AND uncustodied" by reading the green
  possession TOKEN via `BursarClient.query/2` — never `claimed_by`,
  which is a display mirror only (see `Commonplace.Bd.Workspace.claim_path/3`
  and the `ticket_claim`/`ticket_release` verbs in
  `Commonplace.ViewActionDispatch`). The frontier itself
  (`compute/2`/`partition/1`) is untouched, per the design ruling that
  it must never read `claimed_by` or custody.

  A ticket whose claim path doesn't resolve (shouldn't happen for a
  ready ticket, since readiness already required the ticket to exist)
  is treated as uncustodied rather than raising, so a transient lookup
  race degrades to "still eligible" rather than crashing the walk.
  """
  def eligible(root_uuid, store \\ CommitStoreClient) do
    ready_walk(root_uuid, store)
    |> Enum.reject(&claimed?(root_uuid, &1.id, store))
  end

  defp claimed?(root_uuid, id, store) do
    with {:ok, path} <- Workspace.claim_path(root_uuid, id, store),
         {:held, _} <- BursarClient.query(path) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Connected components (over the UNDIRECTED needs graph, local edges
  only) that contain at least one open issue and zero ready issues.
  Empty list means the dependency graph is healthy.

  A `needs` entry that is unresolvable (cross-repo, or a dangling
  local id) does not create an edge to a real node — the issue that
  holds it is simply an isolated (or otherwise-connected) component
  member that can never become ready through that entry.
  """
  def stranded_components(root_uuid, store \\ CommitStoreClient) do
    issues_by_id = load_issues_by_id(root_uuid, store)
    {ready_ids, _blocked_ids} = partition(issues_by_id)
    ready_set = MapSet.new(ready_ids)

    adjacency = build_adjacency(issues_by_id)

    issues_by_id
    |> Map.keys()
    |> connected_components(adjacency)
    |> Enum.filter(fn component ->
      has_open = Enum.any?(component, fn id -> Map.fetch!(issues_by_id, id).status == "open" end)
      has_ready = Enum.any?(component, fn id -> MapSet.member?(ready_set, id) end)
      has_open and not has_ready
    end)
  end

  ## Private

  defp load_issues_by_id(root_uuid, store) do
    Issue.list(root_uuid, store)
    |> Enum.into(%{}, fn {issue, _dir_uuid} -> {issue.id, issue} end)
  end

  defp partition(issues_by_id) do
    Enum.reduce(issues_by_id, {[], []}, fn {id, issue}, {ready, blocked} ->
      cond do
        issue.status != "open" -> {ready, blocked}
        needs_satisfied?(issue, issues_by_id) -> {[id | ready], blocked}
        true -> {ready, [id | blocked]}
      end
    end)
  end

  defp needs_satisfied?(%IssueStruct{needs: needs}, issues_by_id) do
    Enum.all?(needs || [], &entry_satisfied?(&1, issues_by_id))
  end

  # Cross-repo entry: unresolvable in this arc => unsatisfied.
  defp entry_satisfied?(%{"repo" => repo}, _issues_by_id) when is_binary(repo) and repo != "", do: false

  defp entry_satisfied?(%{"ticket" => ticket_id}, issues_by_id) when is_binary(ticket_id) do
    case Map.fetch(issues_by_id, ticket_id) do
      {:ok, target} -> target.status in @satisfied_statuses
      # Dangling local id: unresolvable => unsatisfied.
      :error -> false
    end
  end

  # Malformed entry (missing "ticket") is unresolvable => unsatisfied.
  defp entry_satisfied?(_, _issues_by_id), do: false

  defp to_sorted_issues(ids, issues_by_id) do
    ids
    |> Enum.map(&Map.fetch!(issues_by_id, &1))
    |> Enum.sort_by(& &1.id)
  end

  defp build_adjacency(issues_by_id) do
    Enum.reduce(issues_by_id, %{}, fn {id, issue}, acc ->
      local_targets =
        (issue.needs || [])
        |> Enum.flat_map(fn
          %{"repo" => repo} when is_binary(repo) and repo != "" -> []
          %{"ticket" => target_id} when is_binary(target_id) -> [target_id]
          _ -> []
        end)
        |> Enum.filter(&Map.has_key?(issues_by_id, &1))

      Enum.reduce(local_targets, acc, fn target_id, acc2 ->
        acc2
        |> Map.update(id, MapSet.new([target_id]), &MapSet.put(&1, target_id))
        |> Map.update(target_id, MapSet.new([id]), &MapSet.put(&1, id))
      end)
    end)
  end

  defp connected_components(ids, adjacency) do
    {components, _visited} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {components, visited} ->
        if MapSet.member?(visited, id) do
          {components, visited}
        else
          {component, visited} = bfs_component(id, adjacency, visited)
          {[component | components], visited}
        end
      end)

    components
  end

  defp bfs_component(start_id, adjacency, visited) do
    do_bfs([start_id], adjacency, MapSet.put(visited, start_id), [start_id])
  end

  defp do_bfs([], _adjacency, visited, acc), do: {acc, visited}

  defp do_bfs([id | rest], adjacency, visited, acc) do
    neighbors = Map.get(adjacency, id, MapSet.new())

    {to_visit, visited, acc} =
      Enum.reduce(neighbors, {[], visited, acc}, fn neighbor, {to_visit, visited, acc} ->
        if MapSet.member?(visited, neighbor) do
          {to_visit, visited, acc}
        else
          {[neighbor | to_visit], MapSet.put(visited, neighbor), [neighbor | acc]}
        end
      end)

    do_bfs(to_visit ++ rest, adjacency, visited, acc)
  end
end
