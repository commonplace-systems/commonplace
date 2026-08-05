defmodule Commonplace.Bd.Migrate do
  @moduledoc """
  Bd P2 Slice S5 — the migration importer + three-way verification
  harness that moves a legacy `bd` graph onto Commonplace tickets.

  This module is deliberately separate from `Commonplace.Bd.Importer`
  (the idempotent JSONL importer used for ongoing re-import). The
  migration contract here is a ONE-SHOT, cp-plan-ruled translation:

    * imported set = ALL NON-CLOSED issues (`status` not in
      `["closed", "wontfix"]`); closed/wontfix are archived, not
      imported.
    * `status` is preserved VERBATIM — pure translation, no
      normalization (unlike `Importer.normalize_issue_attrs/1`, which
      coerces unknown/legacy status strings to `"open"`).
    * every imported ticket gets `needs: []` at create time; edges are
      added AFTER, one at a time, through `WriteGuard.check/5` (the
      cycle gate) — never written directly.
    * `done_when: "manual"`, `claimed_by: nil` (no custody tokens
      minted at import — possession is consent-based; workers
      re-claim later via the `ticket_claim` verb), `legacy_id` set to
      the bd id.

  ## `bd export` JSONL shape (CONFIRMED against the real export by the lead)

    * One JSON object per line, same issue-field shape as
      `Commonplace.Bd.Importer` already parses (`id`, `title`,
      `status`, `priority` as an INTEGER 0-3, `issue_type`, `owner`
      the assignee, `description`, ...).
    * Dependency edges are carried as a **per-issue nested field**
      named `"dependencies"` on the DEPENDENT issue's own record
      (issue `Y`'s own `dependencies` list carries the edges where
      `Y` is the dependent). Each entry has the shape
      `%{"issue_id" => Y, "depends_on_id" => X, "type" => "blocks" |
      "parent-child" | "supersedes" | "related"}`, meaning **`Y`
      depends on `X`** (`X` blocks `Y`) — the OPPOSITE arrow direction
      from `Commonplace.Bd.Dep`'s `Edge{from, to}` ("X blocks Y" =
      `Edge{from: X, to: Y}`); here `issue_id` is the blocked party
      and `depends_on_id` is the prereq. This module normalizes both
      into the same internal `%{from: X, to: Y}` shape used
      everywhere else (`from` = prereq, `to` = dependent), so
      downstream C-invariant / guard logic is unchanged.
    * **`type == "blocks"` is the ONLY dependency kind converted into
      `needs`.** The other three kinds seen in the real export
      (`parent-child` — epic/subtask membership, NOT a prerequisite;
      `supersedes`; `related`) are NOT edges in the ready/blocked DAG
      at all and are skipped entirely — not even added to the
      manifest, since skipping them isn't a drop of a real edge, it's
      recognizing they were never a DAG edge. Converting
      `parent-child` into `needs` would be WRONG: a subtask would
      spuriously "need" its still-open parent epic, so the frontier
      would call it blocked while `bd ready` (which only respects
      `blocks`) would call it ready — a three-way mismatch.
    * `import_from_export/4` still accepts an optional 4th argument,
      `deps_jsonl`, a SEPARATE flat JSONL stream of the same
      `{"issue_id","depends_on_id","type"}` objects, used INSTEAD of
      scanning nested per-issue `"dependencies"` fields when the real
      export instead ships dependencies as their own stream. Both
      paths apply the identical `type == "blocks"` filter and `{from,
      to}` direction normalization.
  """

  alias Commonplace.Bd.{Frontier, Issue, WriteGuard, Workspace}
  alias Commonplace.Store.CommitStoreClient

  @non_imported_statuses ~w(closed wontfix)

  @doc """
  Imports every non-closed issue from `export_jsonl` (the `bd export
  --no-memories` JSONL text) into tickets under `root_uuid`, then
  adds dependency edges through the guarded path with the
  C-invariant drop.

  `deps_jsonl` (optional) is a separate flat
  `{"issue_id","depends_on_id","type"}` JSONL stream, used INSTEAD of
  scanning each issue's nested `"dependencies"` field when given —
  see moduledoc for the confirmed export shape and the `type ==
  "blocks"`-only filter this applies either way.

  `opts` (Bd P2 S5) is threaded down every write on this path —
  skeleton creation (`Workspace.ensure_bd_dir/3`), each issue dir +
  entry, and every guarded `needs` edge write — carrying
  `:signing_context` so the whole import can be node-signed and land
  under `local_write_gate: :enforce`. Default `[]` is unsigned
  (permissive) and byte-compatible with every existing caller.

  Returns `{:ok, %{imported: n, skipped_closed: n, manifest: [...],
  edges_added: n}}`.
  """
  def import_from_export(root_uuid, export_jsonl, store \\ CommitStoreClient, deps_jsonl \\ nil, opts \\ []) do
    # The /bd/ skeleton is created here, with `opts`, so its commits
    # carry the migration's signing context (CX-6cz3 kept this
    # explicit when supplied-id creation moved to
    # `Issue.create_with_id/5`, whose own skeleton lookup is
    # opts-less).
    _ = Workspace.ensure_bd_dir(root_uuid, store, opts)

    lines =
      export_jsonl
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    {imported_ids, skipped_closed} = import_issues(root_uuid, lines, store, opts)

    edges = collect_edges(lines, deps_jsonl)
    imported_set = MapSet.new(imported_ids)

    {manifest, edges_added} = apply_edges(root_uuid, edges, imported_set, store, opts)

    {:ok,
     %{
       imported: length(imported_ids),
       skipped_closed: skipped_closed,
       manifest: manifest,
       edges_added: edges_added
     }}
  end

  @doc """
  Three-way verification of the ready-set: the from-scratch query
  (`Frontier.compute/2`), the from-scratch walk
  (`Frontier.ready_walk/2`), and the caller-supplied `bd_cli` set of
  bd-ready ids (parsed by the caller from a real `bd ready` run —
  this function does NOT shell out).

  Returns a map with all three sets plus `agree?` and the pairwise
  differences, so a mismatch is triageable without re-deriving it.
  """
  def three_way(root_uuid, store \\ CommitStoreClient, bd_cli_ready_ids) do
    query = Frontier.compute(root_uuid, store).ready

    walk =
      Frontier.ready_walk(root_uuid, store)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    bd_cli = to_mapset(bd_cli_ready_ids)

    agree? = MapSet.equal?(query, walk) and MapSet.equal?(query, bd_cli)

    %{
      query: query,
      walk: walk,
      bd_cli: bd_cli,
      agree?: agree?,
      only_in_query: MapSet.difference(query, MapSet.union(walk, bd_cli)),
      only_in_walk: MapSet.difference(walk, MapSet.union(query, bd_cli)),
      only_in_bd_cli: MapSet.difference(bd_cli, MapSet.union(query, walk))
    }
  end

  ## Private — issue import

  defp import_issues(root_uuid, lines, store, opts) do
    Enum.reduce(lines, {[], 0}, fn raw, {imported_ids, skipped} ->
      status = Map.get(raw, "status", "open")

      if status in @non_imported_statuses do
        {imported_ids, skipped + 1}
      else
        id = Map.fetch!(raw, "id")
        attrs = to_issue_attrs(raw, status)
        issue = Issue.build_with_id(id, attrs)

        # CX-6cz3: this module's own `create_with_fixed_id` copy is
        # gone — supplied-id creation is `Issue.create_with_id/5`, and
        # every caller of it runs the creation gate first (checked by
        # `Commonplace.Bd.SuppliedIdCreationScanTest`). The allow
        # posture is the import one (`ViewActionDispatch.import_allow_posture/0`,
        # spec-derived): a migration legitimately carries a bd record's
        # own `status`. `needs` is always `[]` here — edges are added
        # afterwards, one at a time, through the cycle gate.
        :ok =
          WriteGuard.check_create(issue, root_uuid, store,
            allow: Commonplace.ViewActionDispatch.import_allow_posture()
          )

        {:ok, _issue, _dir_uuid} =
          Issue.create_with_id(root_uuid, issue, Map.get(attrs, :description, ""), store, opts)

        {[id | imported_ids], skipped}
      end
    end)
    |> then(fn {ids, skipped} -> {Enum.reverse(ids), skipped} end)
  end

  defp to_issue_attrs(raw, status) do
    %{
      title: Map.get(raw, "title", ""),
      status: status,
      priority: normalize_priority(Map.get(raw, "priority")),
      type: Map.get(raw, "issue_type") || Map.get(raw, "type") || "task",
      owner: Map.get(raw, "owner"),
      description: Map.get(raw, "description") || Map.get(raw, "body") || "",
      created_at: Map.get(raw, "created_at"),
      updated_at: Map.get(raw, "updated_at"),
      needs: [],
      done_when: "manual",
      claimed_by: nil,
      legacy_id: Map.fetch!(raw, "id")
    }
  end

  defp normalize_priority(p) when p in [0, 1, 2, 3], do: "p#{p}"
  defp normalize_priority(p) when is_binary(p), do: p
  defp normalize_priority(_), do: "p2"

  ## Private — edge conversion

  # Collects `{from, to, kind}` edges either from the separate
  # `deps_jsonl` stream (when given) or from each issue line's nested
  # `"dependencies"` field (de-duplicated), per the two assumed export
  # shapes documented in the moduledoc. Both paths filter to
  # `type == "blocks"` ONLY — parent-child/supersedes/related are not
  # DAG edges and are dropped silently here (not manifested — they
  # were never a `needs` edge to begin with, so skipping them isn't a
  # C-invariant drop).
  defp collect_edges(_lines, deps_jsonl) when is_binary(deps_jsonl) do
    deps_jsonl
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&blocks_type?/1)
    |> Enum.map(&edge_from_raw/1)
    |> Enum.uniq()
  end

  defp collect_edges(lines, nil) do
    lines
    |> Enum.flat_map(fn raw -> Map.get(raw, "dependencies", []) end)
    |> Enum.filter(&blocks_type?/1)
    |> Enum.map(&edge_from_raw/1)
    |> Enum.uniq()
  end

  defp blocks_type?(m), do: Map.get(m, "type") == "blocks"

  # bd's per-issue dependency entry is `{"issue_id" => Y,
  # "depends_on_id" => X, "type" => "blocks"}` meaning Y depends on X
  # (X blocks Y). Normalize to this module's internal `%{from, to}`
  # shape (from = prereq X, to = dependent Y) — the OPPOSITE key
  # names from the raw bd fields, so this is a direction flip, not a
  # rename.
  defp edge_from_raw(m) do
    %{
      from: Map.fetch!(m, "depends_on_id"),
      to: Map.fetch!(m, "issue_id")
    }
  end

  # For each edge X blocks Y: if X (the prereq) isn't in the imported
  # set, drop it (C-invariant). Otherwise add {ticket: X} to Y.needs
  # through WriteGuard.check/5; a guard refusal (e.g. a latent bd
  # cycle) is manifested and skipped, never forced.
  defp apply_edges(root_uuid, edges, imported_set, store, opts) do
    {manifest, added} =
      Enum.reduce(edges, {[], 0}, fn %{from: x, to: y} = edge, {manifest, added} ->
        cond do
          Map.has_key?(edge, :repo) ->
            add_edge_through_guard(root_uuid, x, y, store, opts, manifest, added)

          not MapSet.member?(imported_set, x) ->
            {[%{from: x, to: y, reason: :prereq_not_imported} | manifest], added}

          not MapSet.member?(imported_set, y) ->
            # Dependent not imported: nothing to attach the edge to.
            {[%{from: x, to: y, reason: :prereq_not_imported} | manifest], added}

          true ->
            add_edge_through_guard(root_uuid, x, y, store, opts, manifest, added)
        end
      end)

    {Enum.reverse(manifest), added}
  end

  defp add_edge_through_guard(root_uuid, x, y, store, opts, manifest, added) do
    with {:ok, y_issue} <- Issue.show(root_uuid, y, store) do
      new_needs = (y_issue.needs || []) ++ [%{"ticket" => x}]
      changes = %{needs: new_needs}

      case WriteGuard.check(y_issue, changes, root_uuid, store, allow: []) do
        :ok ->
          {:ok, _} = Issue.update(root_uuid, y, changes, store, opts)
          {manifest, added + 1}

        {:error, reason} ->
          {[%{from: x, to: y, reason: :guard_refused, detail: reason} | manifest], added}
      end
    else
      {:error, _} ->
        {[%{from: x, to: y, reason: :prereq_not_imported} | manifest], added}
    end
  end

  defp to_mapset(%MapSet{} = s), do: s
  defp to_mapset(list) when is_list(list), do: MapSet.new(list)
end
