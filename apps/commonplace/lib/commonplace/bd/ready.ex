defmodule Commonplace.Bd.Ready do
  @moduledoc """
  P1 `bd ready`/`bd blocked` — RETIRED for the graph queries (CX-hrbn).

  `ready/2` and `blocked/2` filtered `Commonplace.Bd.Dep.list/2` down
  to `blocks` edges. That graph, `/bd/deps.json`, stopped being written
  at the tix-authority cutover on 2026-08-05, so both queries became
  frozen-data oracles wearing a live face. They now raise
  `Commonplace.Bd.RetiredGraphError` rather than returning a
  plausible-looking (and quietly wrong, always short) issue list.

  The live answers come from the `needs` walk:

    * `Commonplace.Bd.Frontier.ready_walk/2` / `.blocked_walk/2` —
      issue structs
    * `Commonplace.Bd.CLI.ready/2` / `.blocked/2` / `.eligible/2` —
      priority-sorted display rows, what `commonplace bd ready` prints

  Note the two oracles genuinely disagree, by design: the P1 rule
  treated an unresolvable blocker as satisfied, while the frontier
  treats it as unsatisfied ("can't become ready on information you
  can't see"). Repointing is a semantic change, not a port. See
  `Commonplace.Bd.Frontier`'s moduledoc, §2 inversion.

  `list_all/2` stays. It never read the frozen graph — it is
  `Issue.list/2` sorted by id — and `commonplace bd list` still uses
  it.
  """

  alias Commonplace.Bd.Issue
  alias Commonplace.Bd.Retired
  alias Commonplace.Store.CommitStoreClient

  @frontier_note "The live ready/blocked oracle walks `needs`, not `blocks` edges, and it answers differently on purpose: an unresolvable prerequisite counts as UNSATISFIED there, where this one counted it satisfied."

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError`; use
  `Commonplace.Bd.CLI.ready/2` or `Commonplace.Bd.Frontier.ready_walk/2`.
  """
  def ready(root_uuid, store \\ CommitStoreClient)

  def ready(_root_uuid, _store) do
    Retired.read!("Commonplace.Bd.Ready.ready/2", @frontier_note)
  end

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError`; use
  `Commonplace.Bd.CLI.blocked/2` or
  `Commonplace.Bd.Frontier.blocked_walk/2`.
  """
  def blocked(root_uuid, store \\ CommitStoreClient)

  def blocked(_root_uuid, _store) do
    Retired.read!("Commonplace.Bd.Ready.blocked/2", @frontier_note)
  end

  @doc """
  Returns every issue, sorted by id.

  Live — this reads `/bd/issues/`, not the retired `/bd/deps.json`.
  """
  def list_all(root_uuid, store \\ CommitStoreClient) do
    Issue.list(root_uuid, store)
    |> Enum.map(fn {issue, _uuid} -> issue end)
    |> Enum.sort_by(& &1.id)
  end
end
