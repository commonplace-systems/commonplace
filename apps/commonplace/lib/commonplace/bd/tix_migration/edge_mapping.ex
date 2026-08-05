defmodule Commonplace.Bd.TixMigration.EdgeMapping do
  @moduledoc """
  THE declared bd→tix edge mapping. One anchor, three consumers.

  Design:
  `/home/jes/commonplace-plan/docs/plans/2026-08-05-tix-authority-migration-design.md`
  §8, "The deps ruling" (2026-08-05, @2588425).

  ## The direction rule

      bd  "A blocks B"   ↦   tix  "B needs A"

  Read it out loud before touching anything here: the ticket that is
  BLOCKED is the one that gains a `needs` ref, and the ref points at
  the ticket that is BLOCKING it. The inverse-direction error is the
  CX-di2m directed-graph lesson — an inverted mapping produces a graph
  that is shaped right, walks fine, and is wrong in every answer it
  gives.

  This mapping is DECLARED EXACTLY ONCE, in `to_needs_ref/1` below,
  and consumed by three call sites (§8: "The importer, the drift
  scanner, and the acceptance check all apply the SAME declared
  mapping"):

    1. the migration driver — `Commonplace.Bd.TixMigration.fold_needs/2`
       (via `bin/tix-migrate`),
    2. the drift scanner — `Commonplace.Bd.TixMigration.bd_edge_projection/1`
       (via `bin/tix-drift`),
    3. the acceptance check — `Commonplace.Bd.TixMigration.three_way/4`,
       which compares the bd leg THROUGH this mapping (a projection
       comparison, not byte equality: bd reads `blocks` edges, tix
       reads `needs` refs, and §3's original "walk == query == bd CLI"
       formula was unrunnable as written once the two-graph split was
       known).

  ## Why the two graphs are not the same graph

  bd's dependencies live in `blocks` edges — in bd's own store, and in
  the substrate mirror `/bd/deps.json` that `Commonplace.Bd.Ready`
  walks (P1). tix's dependencies are P2 `needs` refs on the issue
  record, which is the graph `Commonplace.Bd.Frontier` and the
  `WriteGuard` cycle gate read. Ruling (b) converts at import so the
  26 live tickets' dependencies land in the graph the machinery
  actually reads.

  ## Wire shapes accepted

  bd exports dependency edges in two shapes, and this module
  normalizes both — the direction of each is stated here rather than
  at the parse site, because a wire-shape misreading is a
  direction error wearing a different hat:

    * the `bin/…` deps-stream shape, which
      `Commonplace.Bd.Importer.import_deps_jsonl/3` also consumes:
      `%{"from" => A, "to" => B, "kind" => "blocks"}` — `from` BLOCKS
      `to` (see `Commonplace.Bd.Ready.incoming_blockers/2`, which
      treats `e.to == issue_id` as "issue is blocked by `e.from`").

    * the shape `bd export`'s issue records carry inline under
      `"dependencies"`:
      `%{"issue_id" => B, "depends_on_id" => A, "type" => "blocks"}` —
      B DEPENDS ON A, i.e. A blocks B. Note the field order is the
      reverse of the deps-stream shape's; that asymmetry is exactly
      why both live in one module.

  Only `blocks`-kind edges are in scope for the mapping. A
  `parent-child` (or any other kind) edge is NOT silently discarded —
  `normalize/1` returns a named `{:error, {:not_a_blocks_edge, kind}}`
  so it can be accounted as a refusal against the EDGES-IN
  denominator rather than vanishing from it.
  """

  @blocks_kind "blocks"

  @typedoc "A normalized bd dependency edge: `blocker` blocks `blocked`."
  @type edge :: %{blocker: String.t(), blocked: String.t(), kind: String.t()}

  @typedoc "A tix P2 needs ref, as carried on `Commonplace.Bd.Schemas.Issue`'s `:needs`."
  @type needs_ref :: %{required(String.t()) => String.t()}

  @doc "The one edge kind this mapping covers."
  @spec blocks_kind() :: String.t()
  def blocks_kind, do: @blocks_kind

  @doc """
  THE MAPPING. Given a normalized bd `blocks` edge, returns
  `{ticket_that_gains_the_ref, the_ref}` — that is:

      bd "A blocks B"  ↦  B needs A

  Every consumer goes through this function. Changing the direction
  here changes it everywhere, which is the point.
  """
  @spec to_needs_ref(edge()) :: {String.t(), needs_ref()}
  def to_needs_ref(%{blocker: blocker, blocked: blocked})
      when is_binary(blocker) and is_binary(blocked) do
    {blocked, %{"ticket" => blocker}}
  end

  @doc """
  Normalizes one decoded bd dependency record (either wire shape, see
  the moduledoc) into `{:ok, edge}`.

  Returns `{:error, {:not_a_blocks_edge, kind}}` for an edge of some
  other kind, and `{:error, {:malformed_edge, raw}}` for a record
  whose endpoints are not both binaries. Both are NAMED so the caller
  can account them; neither is a drop.
  """
  @spec normalize(map()) :: {:ok, edge()} | {:error, term()}
  def normalize(%{"from" => from, "to" => to} = raw)
      when is_binary(from) and is_binary(to) do
    build(from, to, Map.get(raw, "kind", @blocks_kind))
  end

  def normalize(%{"depends_on_id" => blocker, "issue_id" => blocked} = raw)
      when is_binary(blocker) and is_binary(blocked) do
    build(blocker, blocked, Map.get(raw, "type") || Map.get(raw, "kind") || @blocks_kind)
  end

  def normalize(raw), do: {:error, {:malformed_edge, raw}}

  defp build(blocker, blocked, kind) when is_binary(kind) do
    if kind == @blocks_kind do
      {:ok, %{blocker: blocker, blocked: blocked, kind: kind}}
    else
      {:error, {:not_a_blocks_edge, kind}}
    end
  end

  defp build(_blocker, _blocked, kind), do: {:error, {:not_a_blocks_edge, inspect(kind)}}

  @doc """
  A stable, printable name for an edge — used as its identity in the
  EDGES-IN denominator, so a refused edge is a named TODO rather than
  a count. Reads in the bd direction (the direction the operator will
  see in `bd dep list`), not the mapped one.
  """
  @spec edge_name(edge() | map()) :: String.t()
  def edge_name(%{blocker: blocker, blocked: blocked}), do: "#{blocker} blocks #{blocked}"

  def edge_name(%{"from" => from, "to" => to}), do: "#{from} blocks #{to}"

  def edge_name(%{"depends_on_id" => blocker, "issue_id" => blocked}),
    do: "#{blocker} blocks #{blocked}"

  def edge_name(raw), do: "<unnamed edge: #{inspect(raw)}>"

  @doc """
  Human-readable statement of the mapping, for scripts to print above
  their reports. An operator reading a migration log should not have
  to open this file to know which way the arrows went.
  """
  @spec direction_statement() :: String.t()
  def direction_statement,
    do: "edge mapping (design §8, @2588425): bd \"A blocks B\" ↦ tix \"B needs A\""
end
