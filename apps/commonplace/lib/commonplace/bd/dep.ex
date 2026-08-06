defmodule Commonplace.Bd.Dep do
  @moduledoc """
  RETIRED — the `/bd/deps.json` dependency graph (CX-hrbn).

  This module was the read/write surface over the P1 `blocks` graph: a
  JSON-encoded text doc holding a flat `%{edge_key => edge_value}` map,
  per spec §2.3/§5.4.

  At the tix-authority cutover on 2026-08-05 the graph stopped being
  written. Prerequisites now live as `needs` refs on each ticket's own
  record, gated by `Commonplace.Bd.WriteGuard` and walked by
  `Commonplace.Bd.Frontier`. That left every function here a live query
  surface over a dead graph — the thing that answers confidently out of
  frozen data (design §5-§8; the §8 ruling's condition 4 gives three
  dispositions: retire, repoint, or refuse loudly).

  These functions take the third. Every one of them raises
  `Commonplace.Bd.RetiredGraphError` naming the cutover and the
  replacement. In particular the readers do NOT return `[]` — see that
  module's note on why the soft failure is the whole defect.

  The document itself is untouched: the store is append-only and
  `/bd/deps.json` remains as archive data.

  Replacements, by what you were doing:

    * listing/inspecting edges → `Commonplace.Bd.Frontier`
    * `bd ready` / `bd blocked` → `Commonplace.Bd.CLI.ready/2`,
      `.blocked/2`, `.eligible/2`
    * adding an edge → the `ticket_add_needs` verb on
      `Commonplace.ViewActionDispatch`
    * removing an edge → `ticket_update` with a revised `needs` list
  """

  alias Commonplace.Bd.Retired
  alias Commonplace.Store.CommitStoreClient

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError`; use the
  `ticket_add_needs` verb.
  """
  def add(root_uuid, from_id, to_id, kind \\ "blocks", attrs \\ %{}, store \\ CommitStoreClient)

  def add(_root_uuid, _from_id, _to_id, _kind, _attrs, _store) do
    Retired.write!("Commonplace.Bd.Dep.add/6")
  end

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError`; revise the
  dependent ticket's `needs` list through `ticket_update`.
  """
  def remove(root_uuid, from_id, to_id, kind \\ "blocks", store \\ CommitStoreClient)

  def remove(_root_uuid, _from_id, _to_id, _kind, _store) do
    Retired.write!(
      "Commonplace.Bd.Dep.remove/5",
      "To drop a prerequisite, dispatch `ticket_update` with the dependent's `needs` list minus that entry — it goes through the same cycle gate."
    )
  end

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError` — deliberately
  never `[]`; use `Commonplace.Bd.Frontier`.
  """
  def list(root_uuid, store \\ CommitStoreClient)

  def list(_root_uuid, _store) do
    Retired.read!("Commonplace.Bd.Dep.list/2")
  end

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError`. Was "edges where
  `to == id`" — things that block `id`. The `needs` equivalent is the
  ticket's own `needs` list (`Commonplace.Bd.Issue.show/3`).
  """
  def incoming(root_uuid, id, kind \\ "blocks", store \\ CommitStoreClient)

  def incoming(_root_uuid, _id, _kind, _store) do
    Retired.read!(
      "Commonplace.Bd.Dep.incoming/4",
      "Its `needs` equivalent — the prereqs of one ticket — is that ticket's own `needs` field: `Commonplace.Bd.Issue.show/3`."
    )
  end

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError`. Was "edges where
  `from == id`" — things `id` blocks. Under `needs` that is a reverse
  scan of every ticket's `needs` list.
  """
  def outgoing(root_uuid, id, kind \\ "blocks", store \\ CommitStoreClient)

  def outgoing(_root_uuid, _id, _kind, _store) do
    Retired.read!(
      "Commonplace.Bd.Dep.outgoing/4",
      "Its `needs` equivalent — the dependents of one ticket — is a reverse scan of every ticket's `needs` list; `Commonplace.Bd.Frontier` already walks that graph."
    )
  end
end
