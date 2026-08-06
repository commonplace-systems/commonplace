defmodule Commonplace.Bd.RetiredGraphError do
  @moduledoc """
  Raised when something calls a surface over `/bd/deps.json` — the P1
  `blocks` dependency graph, retired at the tix-authority cutover on
  2026-08-05.

  ## Why this raises instead of returning `{:error, _}`

  The house idiom is `{:error, reason}`, and this deliberately is not
  that. `{:error, _}` is for a runtime condition a caller might
  reasonably recover from; calling a retired API is a *code* fact,
  fixed at the call site, and the caller's recovery is to stop calling
  it. Raising is what makes it impossible to route around by accident.

  More narrowly: the retired read surface used to return a bare list.
  Every soft alternative — `[]`, `{:ok, []}`, `nil` — is
  indistinguishable from "the graph is live and currently has no
  edges". That indistinguishability IS the defect being closed here
  (design §5-§8: a live query surface over a dead graph, answering
  confidently from frozen data). A raise cannot be mistaken for an
  empty graph.

  Messages are built by `Commonplace.Bd.Retired` so every surface
  points at the same replacement.

  ## Also raised for retired UNGATED WRITE DOORS (CX-xmsd)

  The name says "graph" because the deps graph was the first thing
  retired through it. `Retired.ungated_write!/2` reuses the same
  exception for a different retirement with the same shape: a write
  door that bypasses the gated verb surface. The reasoning above
  carries over unchanged — calling one is a code fact, not a runtime
  condition, and `{:ok, %{imported: 0}}` was indistinguishable from
  success.
  """
  defexception [:message, :surface]
end

defmodule Commonplace.Bd.Retired do
  @moduledoc """
  The retirement notices for the frozen `/bd/deps.json` graph
  (CX-hrbn; cutover CX-dzfv).

  One module so that the text a person hits in six months is written
  once and says the same thing from the library, the CLI, and the
  importer. Each notice answers three questions in order: what did I
  just call, why is it gone, and what do I call instead.
  """

  alias Commonplace.Bd.RetiredGraphError

  @cutover "2026-08-05"
  @design "/home/jes/commonplace-plan/docs/plans/2026-08-05-tix-authority-migration-design.md"

  @doc "The cutover date, so callers quote one constant."
  def cutover, do: @cutover

  @doc """
  Raises `RetiredGraphError` for a read of the frozen graph.

  `surface` is the human-facing name of what was called, e.g.
  `"Commonplace.Bd.Dep.list/2"`.
  """
  def read!(surface, extra \\ nil) do
    raise RetiredGraphError, surface: surface, message: read_notice(surface, extra)
  end

  @doc "Raises `RetiredGraphError` for a write to the frozen graph."
  def write!(surface, extra \\ nil) do
    raise RetiredGraphError, surface: surface, message: write_notice(surface, extra)
  end

  @doc """
  Raises `RetiredGraphError` for a retired UNGATED WRITE DOOR (CX-xmsd).

  Distinct from `write!/2`, which is about the frozen deps graph: this
  is for a write path that still reaches live data but does so around
  the gated verb surface. `replacement` names the verb to call instead
  and is REQUIRED — a retirement notice that does not say what to call
  next just gets routed around.
  """
  def ungated_write!(surface, replacement) when is_binary(replacement) do
    raise RetiredGraphError,
      surface: surface,
      message: ungated_write_notice(surface, replacement)
  end

  @doc "The ungated-write notice as a string (for surfaces that print it)."
  def ungated_write_notice(surface, replacement) do
    """
    #{surface} — RETIRED (ungated write door).

    It wrote through a path that never reached the gated verb surface,
    and it reported a count of its own attempts as if that count were a
    count of what landed. Under Mode-B enforce every one of those writes
    was denied at the store gate while the return value said `{:ok,
    %{imported: N}}` — the 2026-08-05 migration reported "failed: 0" and
    landed ZERO comments (CX-xmsd; measured at the destination, not in
    the report).

    Call this instead:

      #{replacement}

    It threads the caller's signing context, checks every store result,
    and reports landed / no-op / refused against a DECLARED denominator
    built from what arrived — so "0 failed" can no longer coexist with
    "0 landed".

    Ticket: CX-xmsd. Build brief:
    /home/jes/commonplace/docs/plans/2026-08-06-cx-xmsd-gated-comments-build-brief.md
    """
  end

  @doc "The read notice as a string (for CLI surfaces that print it)."
  def read_notice(surface, extra \\ nil) do
    """
    #{surface} — RETIRED (read).

    It read `blocks` edges out of /bd/deps.json. Nothing has written
    that document since the tix-authority cutover on #{@cutover}, when
    ticket authority moved to the substrate tracker. A read of it
    therefore answers from frozen data with a live-sounding voice —
    which is why this raises instead of returning an empty list. An
    empty list would be indistinguishable from a real graph with no
    edges.

    The live prerequisite graph is `needs`, carried on each ticket's
    own record and walked by the frontier:

      Commonplace.Bd.Frontier.ready_walk/2, .blocked_walk/2, .compute/2
      Commonplace.Bd.CLI.ready/2, .eligible/2, .blocked/2  (display rows)
      commonplace bd ready | bd blocked                    (CLI)

    /bd/deps.json itself is untouched. The store is append-only and the
    old edges are still in it as archive data — read them by hand if you
    need the history.
    #{tail(extra)}
    """
  end

  @doc "The write notice as a string (for CLI surfaces that print it)."
  def write_notice(surface, extra \\ nil) do
    """
    #{surface} — RETIRED (write).

    It wrote `blocks` edges into /bd/deps.json. Writing there now would
    revive a graph nothing reads: at the tix-authority cutover on
    #{@cutover}, prerequisites moved onto each ticket's own `needs`
    list, behind the WriteGuard cycle gate. An edge added here would be
    invisible to `bd ready`, to the frontier, and to the acyclicity
    invariant.

    Add a prerequisite with the gated verb instead:

      Commonplace.ViewActionDispatch.dispatch("ticket_add_needs", %{
        args: %{"ticket" => dependent_id, "needs_ticket" => prereq_id},
        signing_context: ctx
      })

    Read the resulting graph through Commonplace.Bd.Frontier.
    #{tail(extra)}
    """
  end

  defp tail(nil), do: "\n    Design: #{@design} §5-§8."
  defp tail(extra), do: "\n    #{extra}\n\n    Design: #{@design} §5-§8."
end
