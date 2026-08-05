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
end
