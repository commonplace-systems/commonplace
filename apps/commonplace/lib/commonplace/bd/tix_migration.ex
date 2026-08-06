defmodule Commonplace.Bd.TixMigration do
  @moduledoc """
  Pure transformation + comparison functions for the bd→tix migration
  (CX-6n62) and the standing bd↔tix drift scanner (CX-q7nh).

  Design:
  `/home/jes/commonplace-plan/docs/plans/2026-08-05-tix-authority-migration-design.md`
  — §3 (the write path and the 3-way acceptance), §4 (scope: the live
  bd-only set now), §6 (order of work), §7 (the gated `ticket_import`
  surface and its rulings), §8 (the deps ruling, @2588425).

  Nothing in this module connects to a node, and nothing here writes.
  It parses a bd export, computes the migration's declared input set,
  folds bd's `blocks` edges into tix `needs` refs through the ONE
  declared mapping (`Commonplace.Bd.TixMigration.EdgeMapping`), builds
  the batch that `ticket_import` consumes, and provides the acceptance
  comparators. The store-touching comparators take the store as an
  argument, like everything else in `Commonplace.Bd.*`.

  ## The denominators

  Two, both built from what ARRIVED rather than from what survived any
  transformation step:

    * RECORDS — `ticket_import` owns this one (`declared_ids` /
      `landed` / `refused` / `noop` / `unaccounted`, ruling (b)). This
      module only decides which records go INTO the batch, and it
      re-measures that set fresh (see `live_set_diff/2`) rather than
      inheriting a dated count. The design's "26 live bd-only" was a
      2026-08-05 measurement and was already stale when it was
      written down.

    * EDGES — this module owns it: `fold_needs/2` reports
      EDGES-IN == LANDED ∪ REFUSED (§8: "no silent pre-cleaning").
      Refusals are EXPECTED, not exceptional: the `blocks` graph has
      never been under any cycle rule, so legacy cycles may exist, and
      a refused edge lands its ticket WITHOUT the edge plus a named
      refusal for human resolution.

  ## Dangling `needs` refs — the decision

  A `blocks` edge has two endpoints, and each can be absent from the
  batch for a different reason with a different answer:

    * The BLOCKER (the ref's target) absent — **the edge still maps.**
      A `needs` ref is `%{"ticket" => id}`; it is shape-valid whether
      or not that ticket exists yet, `WriteGuard`'s ref-type check
      validates shape rather than existence, and the cycle walk simply
      finds nothing to walk. Refusing here would drop real dependency
      information for an accident of batch ordering, and would make
      the migration's output depend on which tickets happen to be
      migrating together — exactly the "silent pre-cleaning" §8
      forbids. It is also self-healing: the ref resolves the moment
      the prerequisite lands, in this batch or a later one.

    * The BLOCKED ticket (the record that would GAIN the ref) absent —
      **named refusal.** There is no record in this batch to carry the
      ref, so nothing could land it; reporting it as landed would be a
      lie, and dropping it would shrink the denominator. It is
      reported as `:dependent_not_in_batch` so an operator can widen
      the batch or add the edge afterwards through `ticket_add_needs`.

  ## The 3-way acceptance (§3, amended by §8)

  `walk == query` over the NEEDS graph in tix, with the bd-CLI leg
  compared THROUGH the declared mapping. `walk_needs/2` reads the
  tree (issue-dir entries under `/bd/issues/`, loading each
  `__issue.json`); `query_needs/3` goes through the id-keyed lookup
  path (`Workspace.issue_dir_uuid/3` per declared id). Two different
  code paths to the same fact — which is the only reason comparing
  them means anything.
  """

  alias Commonplace.Bd.Importer
  alias Commonplace.Bd.Schemas
  alias Commonplace.Bd.TixMigration.EdgeMapping
  alias Commonplace.Bd.Workspace
  alias Commonplace.Store.CommitStoreClient

  # Fields that are TRANSPORT, not record content: bd's export carries
  # its edge graph and its comment stream inline on each issue row.
  # They travel to their own consumers (`fold_needs/2` for the edges,
  # the comments import for the comments) and would otherwise be swept
  # into the tix record's `extra` bag by `Importer.normalize_record/1`
  # — a copy of the edge graph frozen inside every ticket, silently
  # diverging from the needs refs the moment either changes.
  @transport_only_keys ~w(dependencies dependency_count dependent_count comments comment_count)

  @doc """
  The transport-only keys `build_batch/1` strips. Public so the
  stripping is reviewable as DATA rather than inferred from behavior.
  """
  @spec transport_only_keys() :: [String.t()]
  def transport_only_keys, do: @transport_only_keys

  ## --- (a) parsing a bd export set ------------------------------------

  @doc """
  Parses a bd export into `%{records:, parse_refusals:, edges_in:}`.

  `issues_jsonl` is `bd export`'s issue stream, parsed by
  `Commonplace.Bd.Importer.parse_records/1` — the same parser the
  gated verb uses, reused rather than re-implemented. Unparseable
  lines become NAMED parse refusals carrying their line index (the
  same shape the verb produces), never drops.

  `deps_jsonl` is the optional separate dependency stream
  (`%{"from","to","kind"}` lines — the shape
  `Importer.import_deps_jsonl/3` consumed before that leg was retired
  at the 2026-08-05 cutover; here it maps to `needs`). bd ALSO carries its edges
  inline on each issue row under `"dependencies"`, so both sources
  are collected; `EdgeMapping.normalize/1` reads either wire shape.

  EDGES-IN is the DISTINCT set of edges that arrived — an edge
  present in both streams is one edge, not two. Deduplication is by
  endpoints+kind and happens BEFORE any validity judgement, so it can
  never quietly remove an edge that would have been refused.
  """
  @spec parse_export(String.t(), String.t()) :: %{
          records: [map()],
          parse_refusals: [map()],
          edges_in: [map()]
        }
  def parse_export(issues_jsonl, deps_jsonl \\ "")
      when is_binary(issues_jsonl) and is_binary(deps_jsonl) do
    {records, parse_errors} = Importer.parse_records(issues_jsonl)
    {dep_records, dep_parse_errors} = Importer.parse_records(deps_jsonl)

    inline_edges = Enum.flat_map(records, &inline_dependencies/1)

    %{
      records: records,
      parse_refusals:
        Enum.map(parse_errors, &parse_refusal(&1, "issues")) ++
          Enum.map(dep_parse_errors, &parse_refusal(&1, "deps")),
      edges_in: dedupe_edges(inline_edges ++ dep_records)
    }
  end

  defp inline_dependencies(record) when is_map(record) do
    case Map.get(record, "dependencies") do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp inline_dependencies(_), do: []

  # Dedup key: the raw endpoints and kind, read WITHOUT judging them.
  # A record we cannot even read endpoints from gets a unique key, so
  # every malformed edge stays its own named refusal.
  defp dedupe_edges(raw_edges) do
    raw_edges
    |> Enum.with_index()
    |> Enum.uniq_by(fn {raw, idx} -> dedupe_key(raw, idx) end)
    |> Enum.map(fn {raw, _idx} -> raw end)
  end

  defp dedupe_key(%{"from" => from, "to" => to} = raw, _idx),
    do: {from, to, Map.get(raw, "kind", EdgeMapping.blocks_kind())}

  defp dedupe_key(%{"depends_on_id" => blocker, "issue_id" => blocked} = raw, _idx),
    do: {blocker, blocked, Map.get(raw, "type") || Map.get(raw, "kind") || EdgeMapping.blocks_kind()}

  defp dedupe_key(_raw, idx), do: {:unreadable, idx}

  defp parse_refusal({line, reason}, stream) do
    %{
      line: line,
      stream: stream,
      id: "<#{stream} line #{line}: unparseable>",
      reason: "cannot parse line: #{inspect(reason)}"
    }
  end

  ## --- (b) the live-set diff ------------------------------------------

  @doc """
  The migration's input set, RE-MEASURED. Compares the ids present in
  a bd export against the ids present in a tix listing and returns
  `%{bd_only:, tix_only:, both:, bd_total:, tix_total:}` — all lists
  sorted.

  `bd_only` is the migration's declared-EXPECTED denominator: what
  the driver would import on THIS run, derived fresh from the two
  actual corpora. The design's "26 live bd-only" is a dated
  measurement (CX-jfok was filed in bd after it was taken); nothing
  in this pipeline may inherit it.

  `tix_only` is EXPECTED during the transition (§4: nine real
  substrate-only tickets already live in tix) and is reported, not
  treated as an error.
  """
  @spec live_set_diff([String.t()], [String.t()]) :: %{
          bd_only: [String.t()],
          tix_only: [String.t()],
          both: [String.t()],
          bd_total: non_neg_integer(),
          tix_total: non_neg_integer()
        }
  def live_set_diff(bd_ids, tix_ids) when is_list(bd_ids) and is_list(tix_ids) do
    bd = MapSet.new(bd_ids)
    tix = MapSet.new(tix_ids)

    %{
      bd_only: MapSet.difference(bd, tix) |> Enum.sort(),
      tix_only: MapSet.difference(tix, bd) |> Enum.sort(),
      both: MapSet.intersection(bd, tix) |> Enum.sort(),
      bd_total: MapSet.size(bd),
      tix_total: MapSet.size(tix)
    }
  end

  @doc """
  Ids carried by a parsed bd export, in input order. A record with no
  usable id is NOT in this list — it has no id to diff on — but it is
  still a declared input to `ticket_import`, which names it in its own
  denominator (`<record #N: no id>`).
  """
  @spec record_ids([map()]) :: [String.t()]
  def record_ids(records) do
    for r <- records, id = Map.get(r, "id"), is_binary(id) and id != "", do: id
  end

  @doc """
  Selects the records to migrate: those whose id is in `ids`.
  Preserves input order.
  """
  @spec select_records([map()], [String.t()]) :: [map()]
  def select_records(records, ids) do
    wanted = MapSet.new(ids)
    Enum.filter(records, fn r -> Map.get(r, "id") in wanted end)
  end

  ## --- (c) folding deps into needs, through THE mapping ----------------

  @doc """
  Applies `EdgeMapping` to fold `edges_in` into per-record `needs`
  lists, and reports the EDGES accounting.

  Returns `{records, edge_report}` where `edge_report` is

      %{
        edges_in: [name],       # the declared denominator, named
        landed: [name],         # folded into a record's needs
        mapped: [%{edge:, ticket:, prereq:}],   # the same, machine-readable
        refused: [%{edge:, reason:}],
        unaccounted: [name]     # MUST be [] — the identity, checkable at runtime
      }

  The acceptance identity is EDGES-IN == LANDED ∪ REFUSED. It is
  computed here rather than asserted only in a test, so a run that
  breaks it says so.

  NOTE the scope of this report: `landed` here means "folded into the
  batch", which is upstream of the gate. An edge can fold cleanly and
  still not reach tix, because the ticket carrying it was refused by
  the cycle gate. `final_edge_accounting/3` re-runs the identity
  AFTER the import against what tix actually holds; that is the one
  the acceptance check reads.

  `needs` refs are APPENDED to whatever the record already carried
  (present-key semantics — `Importer.normalize_record/1` only carries
  `needs` when the source record has the key) and de-duplicated, so
  folding is idempotent.

  See the moduledoc for the dangling-ref decision: an edge whose
  BLOCKER is absent from the batch still maps; an edge whose BLOCKED
  ticket is absent is a named refusal.
  """
  @spec fold_needs([map()], [map()]) :: {[map()], map()}
  def fold_needs(records, edges_in) when is_list(records) and is_list(edges_in) do
    ids = MapSet.new(record_ids(records))

    {by_ticket, mapped, refused} =
      Enum.reduce(edges_in, {%{}, [], []}, fn raw, {acc, mapped, refused} ->
        name = EdgeMapping.edge_name(raw)

        case EdgeMapping.normalize(raw) do
          {:ok, edge} ->
            {blocked, %{"ticket" => blocker} = ref} = EdgeMapping.to_needs_ref(edge)

            if MapSet.member?(ids, blocked) do
              {Map.update(acc, blocked, [ref], &(&1 ++ [ref])),
               [%{edge: name, ticket: blocked, prereq: blocker} | mapped], refused}
            else
              {acc, mapped,
               [
                 %{
                   edge: name,
                   reason:
                     "dependent_not_in_batch: #{blocked} would gain this needs ref but is not " <>
                       "among the records being imported — widen the batch or add the edge " <>
                       "afterwards with ticket_add_needs"
                 }
                 | refused
               ]}
            end

          {:error, {:not_a_blocks_edge, kind}} ->
            {acc, mapped,
             [
               %{
                 edge: name,
                 reason:
                   "not_a_blocks_edge: kind #{inspect(kind)} — the declared mapping covers " <>
                     "blocks edges only, so this row carries no needs ref"
               }
               | refused
             ]}

          {:error, reason} ->
            {acc, mapped, [%{edge: name, reason: "malformed_edge: #{inspect(reason)}"} | refused]}
        end
      end)

    folded = Enum.map(records, &apply_needs(&1, by_ticket))

    edges_in_names = Enum.map(edges_in, &EdgeMapping.edge_name/1)
    mapped = Enum.reverse(mapped)
    refused = Enum.reverse(refused)
    landed = Enum.map(mapped, & &1.edge)

    accounted = MapSet.new(landed ++ Enum.map(refused, & &1.edge))

    {folded,
     %{
       edges_in: edges_in_names,
       landed: landed,
       mapped: mapped,
       refused: refused,
       unaccounted:
         MapSet.difference(MapSet.new(edges_in_names), accounted) |> Enum.sort()
     }}
  end

  @doc """
  Re-runs the EDGES identity AFTER the import, against what tix
  actually holds.

  `fold_report` is `fold_needs/2`'s second element, `batch_report` is
  the `ticket_import` verb's report, and `tix_graph` is
  `walk_needs/2`'s output. An edge counted as folded but ABSENT from
  the tix needs graph is moved to `refused` with a named reason — the
  gate's own refusal reason when the carrying ticket was refused (the
  EXPECTED case: §8 rules that legacy cycles may exist, since the
  `blocks` graph never lived under a cycle rule, and that a refused
  edge lands its ticket WITHOUT the edge plus a named refusal) — or a
  plain absence statement otherwise.

  The identity `EDGES-IN == LANDED ∪ REFUSED` is recomputed and
  reported as `unaccounted`, which MUST be `[]`.
  """
  @spec final_edge_accounting(map(), map(), map()) :: map()
  def final_edge_accounting(fold_report, batch_report, tix_graph) do
    refusal_by_id = Map.new(Map.get(batch_report, :refused, []), fn r -> {r.id, r.reason} end)

    {landed, post_refused} =
      Enum.reduce(fold_report.mapped, {[], []}, fn %{edge: name, ticket: t, prereq: p}, {l, r} ->
        present? = tix_graph |> Map.get(t, MapSet.new()) |> MapSet.member?(p)

        cond do
          present? ->
            {[name | l], r}

          Map.has_key?(refusal_by_id, t) ->
            {l,
             [
               %{
                 edge: name,
                 reason:
                   "ticket_refused_by_gate: #{t} did not land, so neither did this edge — " <>
                     Map.fetch!(refusal_by_id, t)
               }
               | r
             ]}

          true ->
            {l,
             [
               %{
                 edge: name,
                 reason:
                   "absent_after_import: the tix needs graph has no #{t} -> #{p} ref " <>
                     "even though #{t} is present"
               }
               | r
             ]}
        end
      end)

    landed = Enum.reverse(landed)
    refused = fold_report.refused ++ Enum.reverse(post_refused)
    accounted = MapSet.new(landed ++ Enum.map(refused, & &1.edge))

    %{
      edges_in: fold_report.edges_in,
      landed: landed,
      refused: refused,
      unaccounted:
        MapSet.difference(MapSet.new(fold_report.edges_in), accounted) |> Enum.sort()
    }
  end

  defp apply_needs(record, by_ticket) do
    case Map.fetch(by_ticket, Map.get(record, "id")) do
      {:ok, refs} ->
        existing = Map.get(record, "needs") || []
        Map.put(record, "needs", Enum.uniq(existing ++ refs))

      :error ->
        record
    end
  end

  ## --- (d) the ticket_import batch ------------------------------------

  @doc """
  Builds the records batch `ticket_import` consumes: the folded
  records with the transport-only keys stripped (see
  `transport_only_keys/0`).

  Everything else passes through untouched —
  `Importer.normalize_record/1` inside the verb owns the wire-format
  translation (integer priorities, `issue_type`, `close_reason`, and
  the unknown-field round-trip into `extra`).
  """
  @spec build_batch([map()]) :: [map()]
  def build_batch(records) when is_list(records) do
    Enum.map(records, &Map.drop(&1, @transport_only_keys))
  end

  @doc """
  The comment records carried inline by a bd export, as
  `{issue_id, [record]}` pairs ready for the gated
  `ticket_comments_import` verb (CX-xmsd — `import_comments_jsonl/4`,
  what this used to feed, is retired). Only ids in `only_ids` are
  returned, and only records that actually carry comments.

  The records are handed over RAW, exactly as the export wrote them.
  This used to re-encode each one to JSONL and pre-fill `"body"` from
  `"text"` on the way past — a client-side translation of the very
  field-shape mismatch that made the migration land empty bodies. The
  translation belongs in one place, `Importer.normalize_comment_record/1`,
  inside the gate, where a record it cannot read becomes a NAMED
  refusal in the batch's denominator instead of a silently-defaulted
  empty string out here.

  Non-map entries are kept, not filtered: a comment list entry that is
  not an object is an input the destination must account for, and
  dropping it here would shrink the denominator before anyone counted
  it.
  """
  @spec comment_record_lists([map()], [String.t()]) :: [{String.t(), [term()]}]
  def comment_record_lists(records, only_ids) do
    wanted = MapSet.new(only_ids)

    for record <- records,
        id = Map.get(record, "id"),
        is_binary(id),
        MapSet.member?(wanted, id),
        comments = Map.get(record, "comments"),
        is_list(comments),
        comments != [] do
      {id, comments}
    end
  end

  ## --- (e) the acceptance comparators ---------------------------------

  @doc """
  The tix needs graph read by TREE WALK: every issue-dir entry under
  `/bd/issues/`, loading each `__issue.json`. Returns
  `%{ticket_id => MapSet.t(prereq_id)}` over LOCAL needs refs only
  (a ref carrying `"repo"` is a cross-repo ref and is not part of
  this graph — the same filter `bin/bd-invariants` applies).
  """
  @spec walk_needs(String.t(), module()) :: %{String.t() => MapSet.t()}
  def walk_needs(root_uuid, store \\ CommitStoreClient) do
    Workspace.list_issue_entries(root_uuid, store)
    |> Enum.reduce(%{}, fn entry, acc ->
      case Schemas.load_issue(entry.node_id, store) do
        {:ok, issue} -> Map.put(acc, issue.id, local_needs(issue))
        _ -> acc
      end
    end)
  end

  @doc """
  The same graph read by ID-KEYED QUERY: `Workspace.issue_dir_uuid/3`
  per declared id. Ids that do not resolve are simply absent from the
  result — `three_way/4` reports that as a walk/query disagreement
  rather than papering over it with an empty set.
  """
  @spec query_needs(String.t(), [String.t()], module()) :: %{String.t() => MapSet.t()}
  def query_needs(root_uuid, ids, store \\ CommitStoreClient) do
    Enum.reduce(ids, %{}, fn id, acc ->
      with {:ok, dir_uuid} <- Workspace.issue_dir_uuid(root_uuid, id, store),
           {:ok, issue} <- Schemas.load_issue(dir_uuid, store) do
        Map.put(acc, id, local_needs(issue))
      else
        _ -> acc
      end
    end)
  end

  @doc """
  The same graph, built from already-fetched `%Schemas.Issue{}`
  structs rather than from a store.

  This is what the probe scripts use. They must compute CLIENT-SIDE:
  an `:erpc` to a module the live serve has not loaded force-loads the
  probe's working-tree copy into the serve (CLAUDE.md — an RPC to an
  unloaded module is a WRITE), and `Commonplace.Bd.TixMigration` is by
  definition not loaded there. So the scripts erpc only to
  long-deployed readers (`Bd.Issue.list/2`, `Bd.Issue.show/3`) and
  fold the results here.
  """
  @spec needs_graph_from_issues([struct()]) :: %{String.t() => MapSet.t()}
  def needs_graph_from_issues(issues) do
    Map.new(issues, fn issue -> {issue.id, local_needs(issue)} end)
  end

  defp local_needs(issue) do
    (issue.needs || [])
    |> Enum.filter(&(is_map(&1) and not Map.has_key?(&1, "repo")))
    |> Enum.flat_map(fn
      %{"ticket" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> MapSet.new()
  end

  @doc """
  The bd leg, PROJECTED through the declared mapping into the same
  `%{ticket_id => MapSet.t(prereq_id)}` shape the tix legs use — §8's
  amendment to §3: a projection comparison, not byte equality, since
  bd reads `blocks` edges and tix reads `needs` refs.

  Non-`blocks` and malformed edges are skipped here (they are named
  and accounted by `fold_needs/2`, which owns the EDGES denominator;
  a projection that invented refs for them would compare tix against
  a graph nobody ever intended to write).
  """
  @spec bd_edge_projection([map()]) :: %{String.t() => MapSet.t()}
  def bd_edge_projection(edges_in) when is_list(edges_in) do
    Enum.reduce(edges_in, %{}, fn raw, acc ->
      case EdgeMapping.normalize(raw) do
        {:ok, edge} ->
          {blocked, %{"ticket" => blocker}} = EdgeMapping.to_needs_ref(edge)
          Map.update(acc, blocked, MapSet.new([blocker]), &MapSet.put(&1, blocker))

        {:error, _named_and_accounted_elsewhere} ->
          acc
      end
    end)
  end

  @doc """
  The 3-way acceptance check (§3 as amended by §8), over `scope_ids`
  — the ids the migration declared. Reports:

    * `walk_vs_query` — the two tix read paths must agree exactly.
    * `bd_vs_tix` — the bd projection compared against the tix walk:
      `missing_in_tix` are mapped edges tix does not have (each one a
      refusal that should appear by name in the EDGES accounting);
      `extra_in_tix` are needs refs tix has that bd did not imply
      (expected for tickets that gained edges natively after
      cutover — reported, not judged).

  `agree?` is true only when walk == query AND nothing is missing in
  tix. It is deliberately NOT true-by-emptiness: `scope` carries the
  comparison's size — including `tickets_absent`, the declared ids
  NEITHER leg resolved — so a vacuous pass (nothing compared, or
  almost nothing landed) cannot read as a clean one.
  """
  @spec three_way(map(), map(), map(), [String.t()]) :: map()
  def three_way(walk, query, bd_projection, scope_ids) do
    scope = MapSet.new(scope_ids)

    walk_edges = edge_pairs(walk, scope)
    query_edges = edge_pairs(query, scope)

    only_in_walk = MapSet.difference(walk_edges, query_edges) |> Enum.sort()
    only_in_query = MapSet.difference(query_edges, walk_edges) |> Enum.sort()

    %{missing_in_tix: missing_in_tix, extra_in_tix: extra_in_tix, bd_edges: bd_edges} =
      edge_drift(bd_projection, walk, scope_ids)

    # Ids the walk saw and the query did not (or vice versa) — a
    # missing TICKET, not a missing edge. An id-keyed lookup that
    # cannot resolve a ticket the tree walk found is a real
    # divergence, and edge-set comparison alone would miss it for a
    # ticket with no needs at all.
    walk_ids = walk |> Map.keys() |> MapSet.new() |> MapSet.intersection(scope)
    query_ids = query |> Map.keys() |> MapSet.new() |> MapSet.intersection(scope)

    %{
      scope: %{
        ids: MapSet.size(scope),
        walk_tickets: MapSet.size(walk_ids),
        query_tickets: MapSet.size(query_ids),
        # Declared ids NEITHER leg resolved. Both legs agreeing that a
        # ticket is absent IS agreement — so this is not an
        # `agree?`-breaker (a gate refusal is a finding, not an
        # acceptance failure, per ruling (b)) — but it must be NAMED
        # beside the verdict, or "3 legs agree" over a corpus that
        # landed 2 of 26 reads exactly like a clean pass.
        tickets_absent:
          MapSet.difference(scope, MapSet.union(walk_ids, query_ids)) |> Enum.sort(),
        walk_edges: MapSet.size(walk_edges),
        query_edges: MapSet.size(query_edges),
        bd_edges: bd_edges
      },
      walk_vs_query: %{
        only_in_walk: only_in_walk,
        only_in_query: only_in_query,
        tickets_only_in_walk: MapSet.difference(walk_ids, query_ids) |> Enum.sort(),
        tickets_only_in_query: MapSet.difference(query_ids, walk_ids) |> Enum.sort()
      },
      bd_vs_tix: %{
        missing_in_tix: missing_in_tix,
        extra_in_tix: extra_in_tix
      },
      agree?:
        only_in_walk == [] and only_in_query == [] and missing_in_tix == [] and
          MapSet.equal?(walk_ids, query_ids)
    }
  end

  @doc """
  The EDGE leg on its own — what the drift scanner needs, without a
  second tix read path to compare against.

  `bd_projection` is `bd_edge_projection/1`'s output, `tix_graph` a
  needs graph, and the comparison is scoped to `scope_ids` (the
  scanner passes the ids present on BOTH sides: an edge on a ticket
  tix does not have yet is already reported as an id-set finding, and
  re-reporting it as edge drift would count one fact twice).

  Split out so the scanner does not have to pass the tix graph in as
  both legs of `three_way/4` — a comparison of a thing with itself is
  a check that cannot fail, and one of those wearing the name of an
  acceptance check is worse than no check.
  """
  @spec edge_drift(map(), map(), [String.t()]) :: %{
          missing_in_tix: [{String.t(), String.t()}],
          extra_in_tix: [{String.t(), String.t()}],
          bd_edges: non_neg_integer(),
          tix_edges: non_neg_integer(),
          scope: non_neg_integer()
        }
  def edge_drift(bd_projection, tix_graph, scope_ids) do
    scope = MapSet.new(scope_ids)
    bd_edges = edge_pairs(bd_projection, scope)
    tix_edges = edge_pairs(tix_graph, scope)

    %{
      missing_in_tix: MapSet.difference(bd_edges, tix_edges) |> Enum.sort(),
      extra_in_tix: MapSet.difference(tix_edges, bd_edges) |> Enum.sort(),
      bd_edges: MapSet.size(bd_edges),
      tix_edges: MapSet.size(tix_edges),
      scope: MapSet.size(scope)
    }
  end

  defp edge_pairs(graph, scope) do
    for {ticket, prereqs} <- graph,
        MapSet.member?(scope, ticket),
        prereq <- prereqs,
        into: MapSet.new() do
      {ticket, prereq}
    end
  end

  ## --- field-level divergence (CX-q7nh) --------------------------------

  @doc """
  Field-level divergence for ids present on BOTH sides, compared
  THROUGH `Importer.normalize_record/1` so bd's wire format (integer
  priorities, `issue_type`) is judged against tix's stored form
  rather than against itself.

  `tix_issues` is a map of `id => %Commonplace.Bd.Schemas.Issue{}`.
  Returns a list of per-hit shapes — never a bare count:

      [%{id: "CX-x", field: :status, bd: "open", tix: "closed"}, ...]

  Compares `:status`, `:title` and `:priority` only. That set is
  deliberately narrow and named: they are the fields both stores
  agree on the meaning of, and a scanner that flagged every
  timestamp skew would be noise nobody reads.
  """
  @spec field_divergence([map()], %{String.t() => struct()}) :: [map()]
  def field_divergence(bd_records, tix_issues) do
    Enum.flat_map(bd_records, fn record ->
      with id when is_binary(id) <- Map.get(record, "id"),
           {:ok, issue} <- Map.fetch(tix_issues, id),
           {:ok, attrs, ^id} <- Importer.normalize_record(record) do
        for field <- [:status, :title, :priority],
            bd_value = Map.get(attrs, field),
            tix_value = Map.get(issue, field),
            bd_value != tix_value do
          %{id: id, field: field, bd: bd_value, tix: tix_value}
        end
      else
        _ -> []
      end
    end)
  end
end
