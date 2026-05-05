defmodule Commonplace.Bd.Ready do
  @moduledoc """
  Walk-based `bd ready` query for P1 — no views yet (P2 lifts this
  to a reactive view doc per spec §7).

  Definition: an issue is "ready" when:
    * its `status` is `open` (per spec §7.1 default), and
    * no incoming `blocks` edge from a non-closed issue.

  Cost is O(issues + edges); fine at beads scale (single-digit
  thousands of issues per spec §7).

  Other walk-based queries shipped here for parity with the bd CLI:

    * `blocked/2` — open issues with at least one open blocker.
    * `list/2` — all issues, optionally filtered.
  """

  alias Commonplace.Bd.{Dep, Issue}
  alias Commonplace.Store.CommitStoreClient

  @doc """
  Returns `[%Issue{}]` of issues whose status is `open` and whose
  incoming-blocks edges all originate from closed (or absent) issues.
  """
  def ready(root_uuid, store \\ CommitStoreClient) do
    {issues_by_id, open_issues} = load_open_issues(root_uuid, store)
    edges = Dep.list(root_uuid, store) |> Enum.filter(&(&1.kind == "blocks"))

    Enum.filter(open_issues, fn issue ->
      issue.id
      |> incoming_blockers(edges)
      |> Enum.all?(fn blocker_id ->
        case Map.fetch(issues_by_id, blocker_id) do
          {:ok, blocker} -> blocker.status == "closed" or blocker.status == "wontfix"
          :error -> true
        end
      end)
    end)
  end

  @doc """
  Returns `[%Issue{}]` of open issues with at least one non-closed
  incoming blocker.
  """
  def blocked(root_uuid, store \\ CommitStoreClient) do
    {issues_by_id, open_issues} = load_open_issues(root_uuid, store)
    edges = Dep.list(root_uuid, store) |> Enum.filter(&(&1.kind == "blocks"))

    Enum.filter(open_issues, fn issue ->
      issue.id
      |> incoming_blockers(edges)
      |> Enum.any?(fn blocker_id ->
        case Map.fetch(issues_by_id, blocker_id) do
          {:ok, blocker} -> blocker.status not in ["closed", "wontfix"]
          :error -> false
        end
      end)
    end)
  end

  @doc "Returns every issue, sorted by id."
  def list_all(root_uuid, store \\ CommitStoreClient) do
    Issue.list(root_uuid, store)
    |> Enum.map(fn {issue, _uuid} -> issue end)
    |> Enum.sort_by(& &1.id)
  end

  ## Private

  defp load_open_issues(root_uuid, store) do
    pairs = Issue.list(root_uuid, store)
    issues_by_id = Enum.into(pairs, %{}, fn {issue, _uuid} -> {issue.id, issue} end)
    open = pairs |> Enum.map(fn {issue, _uuid} -> issue end) |> Enum.filter(&(&1.status == "open"))
    {issues_by_id, open}
  end

  defp incoming_blockers(issue_id, edges) do
    edges |> Enum.filter(fn e -> e.to == issue_id end) |> Enum.map(& &1.from)
  end
end
