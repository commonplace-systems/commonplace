defmodule Commonplace.Bd.Invariants do
  @moduledoc """
  Pure, read-only invariant checks over Bd tickets.

  ALARM ONLY: nothing in this module writes, refuses, or mutates
  anything. Wiring a check from here into an enforcement path (a write
  gate, a background scrubber, a repair mutator) is explicitly a
  separate bead — see CX-gvbf's scope note and CX-o3ar.

  ## closed-matches-pin

  `Commonplace.Bd.WriteGuard.frozen_after_close/0` names the fields
  frozen once a ticket closes: `status`, `done_when`, `done_witness`
  ("a ticket closes once in v1; there is no reopen path"). No merge
  path consults `WriteGuard` (it has exactly two callers, both local
  write paths — see `merge_cycle_invariant_test.exs`), so a merge can
  compose a state `WriteGuard` would have refused. `closed_matches_pin/3`
  is the mechanically-checkable version of "did that happen": it
  compares an issue's CURRENT frozen-subset values against the values
  recorded in its terminal-state pin.

  ## Why the pin lives in commit history, not a doc field (CX-gvbf rework)

  An earlier pass stored the pin as an `Issue` doc field
  (`terminal_pin`). That was a vulnerability: it made the pin
  requester-writable state used as the enforcement input. The exact
  same merge that reopens a closed ticket can also rewrite the pin
  that would have caught it — excluding the pin from its own hash
  doesn't help when the comparand itself is rewritable by the same
  write path being checked.

  The fix mirrors the pr-provenance stamp
  (`Commonplace.Bd.CloseGate`'s moduledoc, `metadata[:pr_merge]`): the
  pin rides INSIDE the signed close commit's `metadata`
  (`Commonplace.Bd.Issue.close/4`, via `Schemas.write_text_doc/4`'s
  `:commit_metadata` opt). Commit metadata is content-addressed
  (`Commonplace.Store.Commit.content_address/4`) and therefore bound
  into the commit id and covered by the signer's signature —
  unforgeable without the signer's key, and it needs NO trust in the
  (editable, non-authoritative) doc's own recorded status. So this
  module reads the comparand by WALKING THE ISSUE'S COMMIT HISTORY,
  never from current doc state.

  **Provenance, not position.** The rule keys on whether a commit
  carries the gate's stamp (`metadata[:bd_terminal_pin]`), not on its
  ordinal in the chain. Today there is no reopen gate, so a legal
  history contains at most one stamped close and "latest stamped"
  degenerates to "the one". The walk is written to find the LATEST
  stamped close (newest-first walk, first match wins) rather than
  hardcoding "the only one" so that a future legal reopen — which
  would add a second, later stamped close-transition — is absorbed by
  construction, without changing this module.
  """

  alias Commonplace.Bd.Issue
  alias Commonplace.Bd.Schemas
  alias Commonplace.Bd.Schemas.Issue, as: IssueStruct
  alias Commonplace.Bd.Workspace
  alias Commonplace.Bd.WriteGuard
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  # SINGLE declared frozen-field set — read from WriteGuard, not
  # restated here. See WriteGuard.frozen_after_close/0's doc.
  @frozen_fields WriteGuard.frozen_after_close()

  @bd_terminal_pin_key :bd_terminal_pin

  @doc """
  Returns `:ok`, `{:violation, details}`, or `{:error, reason}` (issue
  or its meta-doc doesn't resolve at all).

  The gate is presence of a STAMPED close in history, NOT the issue's
  CURRENT `status` — a real reopen is exactly a write that moves
  `status` away from `"closed"`, so gating on "is it currently closed"
  would hide the one case this exists to catch. Concretely:

    * no stamped close anywhere in the `__issue.json` chain (issue
      never closed through the gate, OR closed before CX-gvbf shipped
      — a real population, not an oversight) -> `:ok`, nothing to
      compare against.
    * a stamped close exists, frozen subset (current
      `status`/`done_when`/`done_witness` vs. what the LATEST stamped
      close recorded) matches -> `:ok`. This covers both "still
      closed, untouched" and "still closed, but a LEGAL field like
      `title`/`labels` changed" — those aren't in the frozen subset,
      so they never show up here.
    * a stamped close exists, frozen subset differs -> `{:violation,
      %{issue_id: ..., fields: %{field => %{pinned: ..., current: ...}}}}`.
      This is what fires on a reopen: `current.status` is no longer
      `"closed"` but the pin still says it was.
    * a stamped close exists, but its stamp doesn't parse as JSON ->
      `{:violation, %{issue_id: ..., error: {:unparseable_pin, _}}}`
      — a pin that can't be read can't be trusted either, so this is
      reported rather than silently treated as "no pin".
  """
  @spec closed_matches_pin(String.t(), String.t(), module() | atom()) ::
          :ok | {:violation, map()} | {:error, term()}
  def closed_matches_pin(root_uuid, id, store \\ CommitStoreClient) do
    with {:ok, issue} <- Issue.show(root_uuid, id, store),
         {:ok, node_id} <- issue_meta_node_id(root_uuid, id, store) do
      case latest_stamped_pin(store, node_id) do
        nil -> :ok
        pin_json -> compare_against_pin(issue, pin_json)
      end
    end
  end

  defp issue_meta_node_id(root_uuid, id, store) do
    with {:ok, dir_uuid} <- Workspace.issue_dir_uuid(root_uuid, id, store) |> wrap_lookup(),
         {:ok, schema} <- Schemas.load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, Schemas.issue_filename()) |> wrap_lookup() do
      {:ok, entry.node_id}
    end
  end

  defp wrap_lookup({:ok, _} = ok), do: ok
  defp wrap_lookup(:error), do: {:error, :not_found}

  # `commit_log/3` walks newest-first, so the first commit whose
  # metadata carries the stamp IS the latest stamped close — see the
  # moduledoc's "provenance, not position" note.
  defp latest_stamped_pin(store, node_id) do
    store
    |> CommitStoreClient.commit_log(node_id)
    |> Enum.find_value(fn commit -> Map.get(commit.metadata, @bd_terminal_pin_key) end)
  end

  defp compare_against_pin(%IssueStruct{} = issue, pin_json) do
    case Jason.decode(pin_json) do
      {:ok, pinned_map} ->
        compare_frozen_subset(issue, pinned_map)

      {:error, decode_error} ->
        {:violation, %{issue_id: issue.id, error: {:unparseable_pin, decode_error}}}
    end
  end

  defp compare_frozen_subset(%IssueStruct{} = issue, pinned_map) do
    current = %{
      "status" => issue.status,
      "done_when" => issue.done_when,
      "done_witness" => issue.done_witness
    }

    diffs =
      for field <- @frozen_fields,
          key = Atom.to_string(field),
          pinned_value = Map.get(pinned_map, key),
          current_value = Map.get(current, key),
          pinned_value != current_value,
          into: %{} do
        {field, %{pinned: pinned_value, current: current_value}}
      end

    if diffs == %{} do
      :ok
    else
      {:violation, %{issue_id: issue.id, fields: diffs}}
    end
  end

  ## ---------------------------------------------------------------
  ## parses/3 — the BASE invariant. Catches the CX-o3ar corruption
  ## class (concurrent whole-blob rewrites of the same __issue.json
  ## Yjs Text leaf concatenate into unparseable JSON — see
  ## `merge_cycle_invariant_test.exs`'s Q1). Every other check in this
  ## module presupposes a parseable `%IssueStruct{}`; this is the one
  ## that can fire when that presupposition itself is false.
  ## ---------------------------------------------------------------

  @doc """
  Does ticket `id`'s `__issue.json` decode into an `%IssueStruct{}`?

  Returns `:ok` when it parses, `{:violation, %{issue_id:, error:}}`
  when the doc exists but fails to decode (the CX-o3ar class), and
  `{:error, :not_found}` when there is no such ticket at all — that
  is a different failure (nothing to check), not a corruption
  finding, so it is not reported as a violation.
  """
  @spec parses(String.t(), String.t(), module() | atom()) ::
          :ok | {:violation, map()} | {:error, term()}
  def parses(root_uuid, id, store \\ CommitStoreClient) do
    case Issue.show(root_uuid, id, store) do
      {:ok, %IssueStruct{}} ->
        :ok

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:violation, %{issue_id: id, error: reason}}
    end
  end

  ## ---------------------------------------------------------------
  ## acyclic/2 — DIRECTED cycle check over the `needs` graph.
  ##
  ## ⚠️ Deliberately NOT `Frontier.stranded_components/2`: that
  ## builds an UNDIRECTED adjacency and reports only components with
  ## `has_open and not has_ready` — a cycle sharing a connected
  ## component with any ready ticket is invisible to it (measured
  ## 2026-08-05; the general case in a real DAG, since a cycle's
  ## component very often also contains unrelated ready work). This
  ## check instead does a proper directed-graph walk (DFS with a
  ## recursion-stack / back-edge test) so it catches a cycle
  ## regardless of what else shares its component.
  ##
  ## Only LOCAL `needs` entries participate — entries carrying a
  ## `"repo"` key are cross-repo and unwalkable, so they are excluded
  ## as edges (same exclusion `WriteGuard`'s own cycle gate applies).
  ## ---------------------------------------------------------------

  @doc """
  Directed-cycle check over the local `needs` graph for the whole
  corpus under `root_uuid`. Returns `:ok` when acyclic, or
  `{:violation, %{cycles: [[ticket_id, ...], ...]}}` — each inner
  list is one detected cycle, given as the ticket ids that compose
  it, in graph order.

  Tickets whose `__issue.json` fails to parse are silently excluded
  from the walk (that failure is `parses/3`'s job to report, not
  this check's) — `Issue.list/2` already drops them.
  """
  @spec acyclic(String.t(), module() | atom()) :: :ok | {:violation, map()}
  def acyclic(root_uuid, store \\ CommitStoreClient) do
    adjacency =
      root_uuid
      |> Issue.list(store)
      |> Enum.into(%{}, fn {issue, _node_id} -> {issue.id, local_need_targets(issue)} end)

    case find_cycles(adjacency) do
      [] -> :ok
      cycles -> {:violation, %{cycles: cycles}}
    end
  end

  @doc """
  Size of the `needs` digraph `acyclic/2` actually walks: ticket count,
  LOCAL edge count, and how many tickets carry at least one local need.

  This exists because `acyclic: ok` is not self-interpreting. A corpus
  with a rich dependency graph and a corpus whose `needs` were all
  silently dropped by a bug both report "no cycles found" — one because
  there are none, the other because there is nothing to find. Printing
  the scope beside the verdict is what makes a green result readable,
  and is the same false-zero discipline the repo applies to every other
  count: never report a count without the shapes behind it.

  Deliberately NOT folded into `acyclic/2`'s return value — every
  invariant returns the same `:ok | {:violation, _}` shape so the engine
  can treat them uniformly, and special-casing one of them to carry
  telemetry would cost more than it buys.
  """
  @spec needs_graph_stats(String.t(), module() | atom()) :: %{
          tickets: non_neg_integer(),
          local_edges: non_neg_integer(),
          tickets_with_needs: non_neg_integer()
        }
  def needs_graph_stats(root_uuid, store \\ CommitStoreClient) do
    issues = root_uuid |> Issue.list(store) |> Enum.map(fn {issue, _} -> issue end)
    targets = Enum.map(issues, &local_need_targets/1)

    %{
      tickets: length(issues),
      local_edges: targets |> Enum.map(&length/1) |> Enum.sum(),
      tickets_with_needs: Enum.count(targets, &(&1 != []))
    }
  end

  defp local_need_targets(%IssueStruct{needs: needs}) do
    (needs || [])
    |> Enum.filter(fn e -> is_map(e) and not Map.has_key?(e, "repo") end)
    |> Enum.flat_map(fn
      %{"ticket" => t} when is_binary(t) -> [t]
      _ -> []
    end)
  end

  # Iterative-over-roots DFS, explicit gray-set ("in_stack") for the
  # back-edge test. Every unvisited node is walked once overall
  # (standard O(V + E)); a node reachable from multiple roots is only
  # ever explored on its first visit.
  defp find_cycles(adjacency) do
    ids = Map.keys(adjacency)

    {cycles, _state} =
      Enum.reduce(ids, {[], %{visited: MapSet.new(), in_stack: MapSet.new(), stack: []}}, fn id,
                                                                                              {cycles,
                                                                                               state} ->
        if MapSet.member?(state.visited, id) do
          {cycles, state}
        else
          dfs_visit(id, adjacency, cycles, state)
        end
      end)

    Enum.uniq(cycles)
  end

  defp dfs_visit(id, adjacency, cycles, state) do
    state = %{
      state
      | visited: MapSet.put(state.visited, id),
        in_stack: MapSet.put(state.in_stack, id),
        stack: [id | state.stack]
    }

    neighbors = Map.get(adjacency, id, [])

    {cycles, state} =
      Enum.reduce(neighbors, {cycles, state}, fn neighbor, {cycles, state} ->
        cond do
          MapSet.member?(state.in_stack, neighbor) ->
            {[extract_cycle(state.stack, neighbor) | cycles], state}

          MapSet.member?(state.visited, neighbor) ->
            {cycles, state}

          true ->
            dfs_visit(neighbor, adjacency, cycles, state)
        end
      end)

    state = %{
      state
      | in_stack: MapSet.delete(state.in_stack, id),
        stack: tl(state.stack)
    }

    {cycles, state}
  end

  # `stack` is most-recent-first (head = current node). The back edge
  # just found runs current -> target, and target is already
  # somewhere on the stack (it's an ancestor in the current DFS
  # path) — so the cycle is exactly the stack slice from `target`
  # down to `current`, read in forward (target-first) order.
  defp extract_cycle(stack, target) do
    stack
    |> Enum.take_while(&(&1 != target))
    |> then(&(&1 ++ [target]))
    |> Enum.reverse()
  end

  ## ---------------------------------------------------------------
  ## ref_typed/3 — the WriteGuard SHAPE checks (`needs[].ticket`,
  ## `done_witness[]`), applied to RESTING state instead of a
  ## proposed write. Reuses `WriteGuard.validate_needs_shape/2` and
  ## `WriteGuard.validate_done_witness/1` directly (both were `defp`
  ## and are now `def`, narrowly, for exactly this caller) so the
  ## rule is declared in exactly one place — restating WriteGuard's
  ## predicates here would let the two silently drift.
  ## ---------------------------------------------------------------

  @doc """
  Re-judges ticket `id`'s CURRENT `needs`/`done_witness` shape
  against the same rules `WriteGuard.check/5` enforces on a write.
  Returns `:ok`, `{:violation, %{issue_id:, error:}}`, or
  `{:error, reason}` if the ticket doesn't resolve/parse at all
  (see `parses/3` for that failure mode).
  """
  @spec ref_typed(String.t(), String.t(), module() | atom()) ::
          :ok | {:violation, map()} | {:error, term()}
  def ref_typed(root_uuid, id, store \\ CommitStoreClient) do
    case Issue.show(root_uuid, id, store) do
      {:ok, %IssueStruct{} = issue} ->
        with :ok <- WriteGuard.validate_needs_shape(issue.needs || [], root_uuid),
             :ok <- WriteGuard.validate_done_witness(issue.done_witness || []) do
          :ok
        else
          {:error, reason} -> {:violation, %{issue_id: issue.id, error: reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## ---------------------------------------------------------------
  ## check_all/2 — the standing-audit entry point. THIN SHAPE-ADAPTER
  ## over `Commonplace.Invariants.Engine.run/2` (CX-9fyz: the engine
  ## is now the generic runner over the declared registry
  ## (`Commonplace.Invariants.Registry`); this function no longer
  ## enumerates or dispatches anything itself). ALARM ONLY: this
  ## reads, it never writes or refuses anything — see this module's
  ## moduledoc.
  ##
  ## Kept for `bin/bd-invariants` and this module's own callers, which
  ## predate the engine and expect the OLD return shape exactly:
  ## keyed `:parses`/`:closed_matches_pin`/`:ref_typed`/`:acyclic`
  ## (not the registry's `:bd_`-prefixed names), each violation/error
  ## detail carrying `:issue_id` (not the engine's generic `:subject`)
  ## via `Map.put_new` — so a check's own detail map can still name
  ## its subject something more specific (none currently do, but nothing
  ## here would clobber it if one did).
  ## ---------------------------------------------------------------

  @engine_name_to_legacy_key %{
    bd_parses: :parses,
    bd_closed_matches_pin: :closed_matches_pin,
    bd_ref_typed: :ref_typed,
    bd_acyclic: :acyclic
  }

  @doc """
  Runs `parses/3`, `closed_matches_pin/3`, and `ref_typed/3` over
  every ticket under `root_uuid`, plus `acyclic/2` once over the
  whole corpus. Returns a map keyed by invariant name, each value
  `%{checked:, ok:, violations:, errors:}` — `violations` is the
  per-hit detail list (never a bare count), `errors` collects
  non-violation failures (e.g. a ticket that vanished mid-walk).
  """
  @spec check_all(String.t(), module() | atom()) :: map()
  def check_all(root_uuid, store \\ CommitStoreClient) do
    %{results: results} =
      Commonplace.Invariants.Engine.run(%{root_uuid: root_uuid, store: store}, domain: :bd)

    results
    |> Enum.map(fn {engine_name, result} ->
      legacy_key = Map.fetch!(@engine_name_to_legacy_key, engine_name)
      {legacy_key, adapt_result(result)}
    end)
    |> Map.new()
  end

  defp adapt_result(%{checked: checked, ok: ok, violations: violations, errors: errors}) do
    %{
      checked: checked,
      ok: ok,
      violations: Enum.map(violations, &adapt_detail/1),
      errors: Enum.map(errors, &adapt_detail/1)
    }
  end

  # The engine tags per-subject hits with the generic `:subject` key;
  # the pre-engine shape used `:issue_id`. Add it via `Map.put_new`
  # (never overwrite — a check's own detail map wins if it already
  # names the field) so old callers (`bin/bd-invariants`, this
  # module's existing tests) keep reading `:issue_id` unchanged. The
  # whole-corpus check (`acyclic`) has no `:subject` to translate —
  # `Map.put_new` on a map without `:subject` is a no-op.
  defp adapt_detail(%{subject: subject} = detail) do
    detail |> Map.put_new(:issue_id, subject)
  end

  defp adapt_detail(detail), do: detail

  @doc """
  Every ticket id under `root_uuid` — the per-subject enumeration
  entry point `Commonplace.Invariants.Registry`'s three `:per_subject`
  bd invariants (`:bd_parses`, `:bd_ref_typed`, `:bd_closed_matches_pin`)
  use as their `enumerate` fun, and what `check_all/2` (below) also
  uses so there is exactly one place that knows how a ticket id maps
  to its directory entry name. Promoted from `defp` for exactly this
  caller — reuses `Workspace.list_issue_entries/2` (the same
  enumeration `Issue.list/2` builds on) rather than re-walking the
  /bd/issues/ schema a second time.
  """
  @spec ticket_ids(String.t(), module() | atom()) :: [String.t()]
  def ticket_ids(root_uuid, store) do
    root_uuid
    |> Workspace.list_issue_entries(store)
    |> Enum.map(fn e -> String.trim_trailing(e.name, ".iss") end)
  end
end
