defmodule Commonplace.Bd.WriteGuard do
  @moduledoc """
  Slice S1 Part 3 — the ONE shared write-guard chokepoint. Every
  ticket-mutating VERB (`Commonplace.ViewActionDispatch`'s
  `ticket_add_needs` / `ticket_update`, and future S3/S4 gate verbs)
  calls `check/5` before landing a mutating commit.

  `Commonplace.Bd.*` (`Issue`, `Dep`, ...) stays the LIBRARY layer —
  it does no enforcement of its own. This module is the single place
  that decides whether a proposed set of field changes is allowed to
  land, given:

    * **ref-type shape checks** — `needs[].ticket` (:-ref),
      `done_witness[]` (@-ref), `claimed_by` (principal-ref). These
      validate SHAPE only — no existence/fetchability resolution in
      S1 (that's the S3 close-gate's job for `done_witness`, and a
      future concern for `needs[].ticket`). A `needs` entry whose
      `"repo"` names the LOCAL root is refused here as a self-repo ref
      ("use the local form") — it is semantically local but would slip
      past the cross-repo-leaf classification below and skip the cycle
      walk, so the form rule closes that bypass before the walk runs.
    * **protected-field enforcement** — `status`, `done_witness`,
      `claimed_by` are GATE-EXCLUSIVE: refused unless the caller's
      `allow` list explicitly names them. Generic verbs pass
      `allow: []`.
    * **the cycle gate** — when a write GROWS `needs` (adds one or
      more *local* prereq entries — no `"repo"` key), each added edge
      is checked: does walking the prereq's own local-needs-ancestors
      chain reach back to the dependent ticket? If so, the edge would
      close a cycle and the write is refused. Cross-repo entries (with
      `"repo"`) are treated as unwalkable leaves — cycle prevention is
      best-effort/local per the S1 design, not a cross-repo guarantee.

  Bd P2 Slice S3 (the close-gate) adds three more checks, all in THIS
  chokepoint (never left to `ticket_close` alone), because `done_when`
  is writable via `ticket_update` too, not just at close:

    * **`done_when` shape** — `"manual"` (string) or exactly
      `%{"type" => "pr_merge", "target" => <non-empty string>}` (no
      extra keys). Anything else is refused. v1 has only these two
      types; a future type extends this validator, not `ticket_close`.
    * **`done_when` monotonicity (strengthening-only)** — a ladder,
      `manual(0) < pr_merge(1)`. A write that downgrades (`pr_merge` ->
      `manual`) is refused. A write that keeps the same `type` but
      changes its params (e.g. `pr_merge` target A -> target B) is
      refused too — params are immutable once set, not just
      monotonic-non-decreasing (there is no total order over two
      different pr_merge targets, so "same rank, different value" is
      its own refusal case, not a strengthen). A byte-identical
      no-op (same type, same params) is always accepted.
    * **post-close freeze** — once `issue.status == "closed"`,
      `done_when`, `done_witness`, and `status` itself are frozen:
      refused regardless of `allow`. A ticket closes once in v1; there
      is no reopen path. This is checked FIRST (before protected-field
      `allow`-list enforcement) precisely because it must NOT be
      bypassable by any caller's `allow` list, unlike the ordinary
      protected-field gate below.
  """

  alias Commonplace.Bd.Schemas
  alias Commonplace.Bd.Schemas.Issue
  alias Commonplace.Bd.Workspace
  alias Commonplace.Store.CommitStoreClient

  @protected_fields [:status, :done_witness, :claimed_by]

  @doc """
  Checks a proposed set of field `changes` against `issue` (the
  CURRENT state of the ticket being written). `changes` is an
  atom-keyed map — e.g. `%{needs: [...]}`, `%{status: "closed"}` —
  giving each proposed field's FINAL value (not a delta), matching
  `Commonplace.Bd.Issue.update/5`'s `attrs` shape.

  `opts[:allow]` is the list of protected-field atoms this caller's
  gate is authorized to write (default `[]` — nothing protected is
  writable).

  Returns `:ok` or `{:error, reason_string}`.
  """
  @spec check(Issue.t(), map(), String.t(), module() | atom(), keyword()) ::
          :ok | {:error, String.t()}
  def check(%Issue{} = issue, changes, root_uuid, store \\ CommitStoreClient, opts \\ [])
      when is_map(changes) and is_binary(root_uuid) do
    allow = Keyword.get(opts, :allow, [])

    with :ok <- check_frozen(issue, changes),
         :ok <- check_protected(changes, allow),
         :ok <- check_ref_types(changes, root_uuid),
         :ok <- check_done_when_monotonic(issue, changes),
         :ok <- check_cycle(issue, changes, root_uuid, store) do
      :ok
    end
  end

  ## Post-close freeze (S3) — runs BEFORE protected-field enforcement so
  ## it can never be bypassed by an `allow` list. A closed ticket never
  ## reopens in v1: `status`, `done_when`, and `done_witness` are frozen
  ## solid once `issue.status == "closed"`.

  @frozen_after_close [:status, :done_when, :done_witness]

  @doc """
  The single declared set of fields frozen once a ticket closes.
  `check_frozen/2` (below) and `Commonplace.Bd.Invariants`'s
  closed-matches-pin comparison both read THIS list rather than each
  keeping their own copy — a widened set only has to change here, and
  a second silently-narrower copy can't drift back out of sync with
  what's actually enforced.
  """
  @spec frozen_after_close() :: [atom()]
  def frozen_after_close, do: @frozen_after_close

  defp check_frozen(%Issue{status: "closed"}, changes) do
    changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @frozen_after_close))
    |> case do
      [] ->
        :ok

      [field | _] ->
        {:error, "field #{inspect(field)} is frozen: ticket is closed (no reopen in v1)"}
    end
  end

  defp check_frozen(%Issue{}, _changes), do: :ok

  ## Protected-field enforcement

  defp check_protected(changes, allow) do
    changes
    |> Map.keys()
    |> Enum.filter(&(&1 in @protected_fields))
    |> Enum.reject(&(&1 in allow))
    |> case do
      [] ->
        :ok

      [field | _] ->
        {:error,
         "field #{inspect(field)} is gate-protected and cannot be written on this path (not in allow list)"}
    end
  end

  ## Ref-type shape checks

  defp check_ref_types(changes, root_uuid) do
    with :ok <- maybe_validate(changes, :needs, &validate_needs_shape(&1, root_uuid)),
         :ok <- maybe_validate(changes, :done_when, &validate_done_when_shape/1),
         :ok <- maybe_validate(changes, :done_witness, &validate_done_witness/1),
         :ok <- maybe_validate(changes, :claimed_by, &validate_claimed_by/1) do
      :ok
    end
  end

  defp maybe_validate(changes, key, validator) do
    case Map.fetch(changes, key) do
      {:ok, value} -> validator.(value)
      :error -> :ok
    end
  end

  defp validate_needs_shape(needs, root_uuid) when is_list(needs) do
    Enum.reduce_while(needs, :ok, fn entry, :ok ->
      case validate_need_entry(entry, root_uuid) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_needs_shape(_, _), do: {:error, "needs must be a list"}

  @need_entry_keys MapSet.new(["ticket", "repo"])

  defp validate_need_entry(%{"ticket" => ticket} = m, root_uuid) when is_binary(ticket) and ticket != "" do
    keys = m |> Map.keys() |> MapSet.new()

    cond do
      not MapSet.subset?(keys, @need_entry_keys) ->
        unexpected = MapSet.difference(keys, @need_entry_keys) |> MapSet.to_list()
        {:error, "needs entry has unexpected keys: #{inspect(unexpected)}"}

      Map.has_key?(m, "repo") and not (is_binary(m["repo"]) and m["repo"] != "") ->
        {:error, "needs entry \"repo\" must be a non-empty string when present"}

      # A `repo` naming the LOCAL root is a self-repo ref: semantically
      # local, but the cross-repo-leaf classification (§cycle gate) would
      # skip the cycle walk for it — a gate bypass reachable by just
      # naming your own repo. Refuse the FORM (don't silently normalize —
      # that hides the caller's confusion). Pre-T1 the local root_uuid is
      # the only real repo id; revisit the comparison when T1 defines
      # trust-root ids.
      Map.get(m, "repo") == root_uuid ->
        {:error, "self-repo ref: use the local form"}

      true ->
        :ok
    end
  end

  defp validate_need_entry(_, _) do
    {:error, "needs entry must be a map with a non-empty string \"ticket\" key"}
  end

  ## done_when shape (S3): "manual" (string) or exactly
  ## %{"type" => "pr_merge", "target" => <non-empty string>} — no extra
  ## keys. Future done_when types extend this validator (a designer-
  ## reviewed dispatch plug-point), not `ticket_close`.

  @done_when_keys MapSet.new(["type", "target"])

  defp validate_done_when_shape("manual"), do: :ok

  defp validate_done_when_shape(%{"type" => "pr_merge", "target" => target} = m)
       when is_binary(target) and target != "" do
    keys = m |> Map.keys() |> MapSet.new()

    if MapSet.equal?(keys, @done_when_keys) do
      :ok
    else
      {:error, "done_when pr_merge entry must have exactly \"type\" and \"target\" keys"}
    end
  end

  defp validate_done_when_shape(_) do
    {:error,
     "done_when must be \"manual\" or a map of exactly %{\"type\" => \"pr_merge\", \"target\" => <non-empty string>}"}
  end

  defp validate_done_witness(list) when is_list(list) do
    if Enum.all?(list, &hex_cid?/1) do
      :ok
    else
      {:error, "done_witness entries must be lowercase hex strings"}
    end
  end

  defp validate_done_witness(_), do: {:error, "done_witness must be a list"}

  defp hex_cid?(s) when is_binary(s) and byte_size(s) > 0, do: Regex.match?(~r/^[0-9a-f]+$/, s)
  defp hex_cid?(_), do: false

  defp validate_claimed_by(nil), do: :ok

  defp validate_claimed_by(s) when is_binary(s) do
    case String.split(s, "@") do
      [id, pub] when id != "" and pub != "" -> :ok
      _ -> {:error, "claimed_by must be of the form identity_uuid@pubkey"}
    end
  end

  defp validate_claimed_by(_), do: {:error, "claimed_by must be a string or nil"}

  ## done_when monotonicity (S3) — strengthening-only. Runs AFTER shape
  ## validation (`check_ref_types`), so `new` here is already
  ## well-formed. A ladder rank: manual(0) < pr_merge(1). A downgrade
  ## (new rank < old rank) is refused. A same-rank change with DIFFERENT
  ## params (e.g. pr_merge target A -> target B) is refused too — params
  ## are immutable once set, not merely non-decreasing (there is no
  ## meaningful order between two different pr_merge targets). A
  ## byte-identical no-op is always accepted, checked first so it never
  ## falls into the same-rank-different-params refusal.

  defp check_done_when_monotonic(%Issue{done_when: old}, changes) do
    case Map.fetch(changes, :done_when) do
      {:ok, new} -> validate_done_when_transition(old, new)
      :error -> :ok
    end
  end

  defp validate_done_when_transition(same, same), do: :ok

  defp validate_done_when_transition(old, new) do
    old_rank = done_when_rank(old)
    new_rank = done_when_rank(new)

    cond do
      new_rank < old_rank ->
        {:error,
         "done_when cannot be downgraded (#{done_when_label(old)} -> #{done_when_label(new)})"}

      new_rank == old_rank ->
        {:error,
         "done_when params cannot be changed once set (#{done_when_label(old)} -> #{done_when_label(new)})"}

      true ->
        :ok
    end
  end

  defp done_when_rank("manual"), do: 0
  defp done_when_rank(%{"type" => "pr_merge"}), do: 1
  defp done_when_rank(_), do: -1

  defp done_when_label("manual"), do: "manual"
  defp done_when_label(%{"type" => type}), do: type
  defp done_when_label(other), do: inspect(other)

  ## Cycle gate

  defp check_cycle(%Issue{} = issue, changes, root_uuid, store) do
    case Map.fetch(changes, :needs) do
      {:ok, new_needs} when is_list(new_needs) ->
        added = added_needs(issue.needs || [], new_needs)
        cycle_check(issue.id, added, root_uuid, store)

      _ ->
        :ok
    end
  end

  defp added_needs(old_needs, new_needs) do
    old_keys = old_needs |> Enum.map(&need_key/1) |> MapSet.new()
    Enum.reject(new_needs, fn e -> MapSet.member?(old_keys, need_key(e)) end)
  end

  defp need_key(%{"ticket" => t} = m), do: {t, Map.get(m, "repo")}
  defp need_key(_), do: make_ref()

  defp cycle_check(dependent_id, added_entries, root_uuid, store) do
    added_entries
    |> Enum.filter(fn e -> is_map(e) and not Map.has_key?(e, "repo") end)
    |> Enum.reduce_while(:ok, fn %{"ticket" => prereq_id}, :ok ->
      if reaches?(prereq_id, dependent_id, root_uuid, store, MapSet.new()) do
        {:halt, {:error, "adding this dependency would create a cycle"}}
      else
        {:cont, :ok}
      end
    end)
  end

  # Does walking `current_id`'s local-needs-ancestors chain reach
  # `target_id`? Base case (current_id == target_id) is checked at
  # entry so a direct self-need is also caught. `visited` guards
  # against infinite loops on any PRE-EXISTING cycle in visible data.
  defp reaches?(current_id, target_id, root_uuid, store, visited) do
    cond do
      current_id == target_id ->
        true

      MapSet.member?(visited, current_id) ->
        false

      true ->
        visited = MapSet.put(visited, current_id)

        case load_needs(current_id, root_uuid, store) do
          {:ok, local_needs} ->
            Enum.any?(local_needs, fn %{"ticket" => t} ->
              reaches?(t, target_id, root_uuid, store, visited)
            end)

          :error ->
            false
        end
    end
  end

  defp load_needs(id, root_uuid, store) do
    with {:ok, dir_uuid} <- Workspace.issue_dir_uuid(root_uuid, id, store),
         {:ok, %Issue{needs: needs}} <- Schemas.load_issue(dir_uuid, store) do
      local = Enum.filter(needs || [], fn e -> is_map(e) and not Map.has_key?(e, "repo") end)
      {:ok, local}
    else
      _ -> :error
    end
  end
end
