defmodule Commonplace.Bd.CLI do
  @moduledoc """
  Thin CLI/query layer over the on-substrate ticket-DAG (Bd P2).

  A plain-function query/action API — no escript/IO framework. Queries
  read through `Commonplace.Bd.Frontier`; actions are thin wrappers
  over `Commonplace.ViewActionDispatch`'s `ticket_claim`/`ticket_close`
  verbs, threading a caller-supplied `signing_context`. This module is
  the logic layer, cleanly testable against an isolated store; a mix
  task or an RPC shim (calling into a live serve) is a thin transport
  wrapper on top, not built here.

  ## Display rows

  Queries return lists of a small display map:

      %{id: "CX-abc", priority: "p1", type: "bug", title: "...",
        status: "open", claimed_by: nil}

  A plain map (not a struct) — this is a read-only projection for
  display/piping, not a domain entity; callers needing the full ticket
  reach for `Commonplace.Bd.Issue.show/3`.

  Sorted by priority (`p0` < `p1` < `p2` < `p3`, unknown priorities
  sort last) then by id, so the most urgent, lowest-id work leads.
  """

  alias Commonplace.Bd.Frontier
  alias Commonplace.Bd.Schemas.Issue, as: IssueStruct
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.ViewActionDispatch

  @priority_rank %{"p0" => 0, "p1" => 1, "p2" => 2, "p3" => 3}

  @doc "Ready tickets (Frontier.compute.ready), priority-sorted."
  def ready(root_uuid, store \\ CommitStoreClient) do
    Frontier.ready_walk(root_uuid, store)
    |> to_rows()
    |> sort_rows()
  end

  @doc "Ready tickets minus claimed (Frontier.eligible), priority-sorted."
  def eligible(root_uuid, store \\ CommitStoreClient) do
    Frontier.eligible(root_uuid, store)
    |> to_rows()
    |> sort_rows()
  end

  @doc "Open-but-blocked tickets (Frontier.compute.blocked), priority-sorted."
  def blocked(root_uuid, store \\ CommitStoreClient) do
    Frontier.blocked_walk(root_uuid, store)
    |> to_rows()
    |> sort_rows()
  end

  @doc """
  Formats a row list as aligned text lines for terminal display, e.g.

      ○ CX-abc  p1  bug   fix the thing

  Pure string function.
  """
  def render(rows) when is_list(rows) do
    rows
    |> Enum.map(&render_row/1)
    |> Enum.join("\n")
  end

  defp render_row(%{id: id, priority: priority, type: type, title: title}) do
    "○ #{String.pad_trailing(id, 10)} #{String.pad_trailing(priority, 4)} #{String.pad_trailing(type, 6)} #{title}"
  end

  @doc """
  Claims `id` as the principal derived from `signing_context`. Thin
  wrapper over the `ticket_claim` verb. Returns `{:ok, claimed_by}` or
  `{:error, reason}`.
  """
  def claim(root_uuid, id, signing_context, store \\ CommitStoreClient)

  # `root_uuid` is accepted for a consistent call shape with the other
  # public functions here (and because the dispatch verb resolves the
  # SAME root via `Workspace.root_uuid/0` under the hood — see the
  # moduledoc), but is not itself threaded into the dispatch context.
  def claim(_root_uuid, id, signing_context, store) do
    context = dispatch_context(%{"ticket" => id}, signing_context, store)

    case ViewActionDispatch.dispatch("ticket_claim", context) do
      {:ok, :tree_mutation, %{claimed_by: claimed_by}} -> {:ok, claimed_by}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Closes `id` with the given candidate `witnesses` (a list of hex
  cids). Thin wrapper over the `ticket_close` verb. Returns
  `{:ok, status}` or `{:error, reason}`.
  """
  def close(root_uuid, id, witnesses, signing_context, store \\ CommitStoreClient)

  # See `claim/4`'s note on `root_uuid`.
  def close(_root_uuid, id, witnesses, signing_context, store) do
    context =
      dispatch_context(%{"ticket" => id, "witnesses" => witnesses}, signing_context, store)

    case ViewActionDispatch.dispatch("ticket_close", context) do
      {:ok, :tree_mutation, %{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Private

  defp dispatch_context(args, signing_context, store) do
    %{
      args: args,
      signing_context: signing_context,
      source: "bd_cli",
      store: store
    }
  end

  defp to_rows(issues) do
    Enum.map(issues, &to_row/1)
  end

  defp to_row(%IssueStruct{} = issue) do
    %{
      id: issue.id,
      priority: issue.priority,
      type: issue.type,
      title: issue.title,
      status: issue.status,
      claimed_by: issue.claimed_by
    }
  end

  defp sort_rows(rows) do
    Enum.sort_by(rows, fn row -> {Map.get(@priority_rank, row.priority, 99), row.id} end)
  end
end
