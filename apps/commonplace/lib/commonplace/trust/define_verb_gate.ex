defmodule Commonplace.Trust.DefineVerbGate do
  @moduledoc """
  CX-ndvi §1.1/§5 — the `:define_verb` contributor walk that gates SAFE
  MUD verb docs. Mirrors `Commonplace.Trust.authorized_to_execute?/3`
  (Gate B)'s soundness argument exactly, but for a DIFFERENT execution
  class: a verb doc is never gated on player `:execute` (untrusted
  players never hold it — the VERB RUNNER holds `:execute`, not the
  player); it is gated on `:define_verb`, scoped to the SECTION the verb
  lives under (its host object/room), not the verb doc's own freshly-
  minted uuid (which no pre-existing section cert could possibly list).

  This module is intentionally a NEW, separate module rather than an
  addition to `Commonplace.Trust` itself (CX-ndvi constraint: don't
  modify `trust.ex`'s existing behavior) — it calls only the PUBLIC
  `Commonplace.Trust.authorized?/5` and `Commonplace.Trust.config/0`,
  never touching Trust's internals, so Gate A/Gate B/the local-write
  gate are all provably unaffected by this file's existence.

  ## Why "section_scope" instead of the verb doc's own uuid

  A section cert's `{:docs, uuids}` scope is a FROZEN list captured at
  mint time — the object/room uuids that existed when the section was
  founded. A verb doc created later under `<object>/verbs/<name>.elx`
  has a fresh uuid no existing cert could have listed (the exact "new
  room" gap `Commonplace.MUD.Sections.auto_extend_for_new_room/3`
  documents for rooms). Rather than reissuing certs every time a verb is
  saved, the DEFINE check is anchored on the caller-supplied
  `section_scope` (typically `[host_object_or_room_uuid]` — the anchor
  uuid(s) that DO appear in the owner's section cert) instead of the
  verb doc's own uuid. `Commonplace.Code.SourceDoc.compile/3`'s
  `{:verb, section_scope}` gate class passes this straight through.

  ## Contributor walk, not head-only

  Same laundering argument as Gate B (design doc §2): the verb-editor
  flow re-encodes FULL doc state on every save, so a trusted head commit
  physically contains an earlier untrusted contributor's bytes. Every
  commit contributing to the verb doc's history (since genesis) must be
  authorized for `:define_verb` over AT LEAST ONE `section_scope` uuid,
  or the walk denies.

  ## HONESTY BOUNDARY (load-bearing — see CX-ndvi build spec)

  This gate controls WHO may cause a verb doc's bytes to be compiled and
  dispatched — it says nothing about what the compiled code can do at
  runtime. Runtime effect containment is the `Commonplace.MUD.World.Facade`
  (least-authority) plus `Commonplace.MUD.SafeVerb.Lint` (raised bar for
  hostile code, not a sandbox) — true hostile-code containment is
  OS-level isolation, phase-4, banked. This module is the DEFINE-time
  authority check only.

  ## No watermark cache (deliberate MVP scope-cut)

  Gate B's execute-walk has a per-doc watermark cache
  (`CommitStore.get/put_execute_clean`) to bound repeated-invocation
  cost. This module does NOT reuse that mechanism yet — the design doc
  (Axis E) explicitly buckets "define-walk caching (watermark-style)"
  under Phase 2, not MVP. Every `SourceDoc.compile/3` call with a
  `{:verb, _}` gate re-walks the full contributor chain. Correct, not
  yet optimized — flagged in the CX-ndvi completion report.

  ## Paging (CX-klpi held half)

  Same paging shell as `Commonplace.Trust.authorized_to_execute?/4`
  (see its moduledoc for the full rationale) — the walk pages through
  the chain via `CommitStoreClient.commit_log/3` +
  `commit_log_from/3`, `page_size` at a time (default
  `CommitStore.max_commit_log_limit/0`, overridable via
  `opts[:page_size]`), bounded overall by
  `Application.get_env(:commonplace, :max_authorization_walk_commits,
  200_000)`. Without the watermark cache above, EVERY define-walk here
  pages through the doc's full history on every call — there is no
  "subsequent walks halt near head" amortization for this gate (that's
  the Phase 2 cache work referenced above), so a legitimately long verb
  doc history is a real per-call paging cost here, not just a cold-cache
  one.

  Two new failure modes:

    * `{:error, {:authorization_chain_incomplete, commit_id}}` — a page
      came back short of `page_size` but its last commit is neither
      `kind: :genesis` nor parent-less: the chain visibly continues but
      the store doesn't have the next commit.
    * `{:error, {:authorization_chain_too_long, n}}` — the total ceiling
      was exceeded before the walk halted.

  This REMOVES the CX-klpi mechanical half's truncation warning/telemetry
  — paging makes silent truncation impossible.
  """

  require Logger

  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Trust

  @doc """
  Is every commit contributing to `doc_uuid`'s state authorized for
  `:define_verb` over at least one uuid in `section_scope`?

  Returns `:ok` or `{:error, {:undefined_contributor, commit_id, reason}}`.
  An empty chain (doc not found / no commits) returns `:ok` — same
  convention as `authorized_to_execute?/3`; the caller's own read fails
  with `:not_found` independently.
  """
  @spec authorized_to_define?(
          GenServer.server(),
          String.t(),
          [String.t()],
          Trust.config() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def authorized_to_define?(store, doc_uuid, section_scope, cfg \\ nil, opts \\ [])
      when is_list(section_scope) do
    cfg = cfg || Trust.config()

    if cfg.accept_unsigned and cfg.trusted_identities == %{} do
      # Fully-permissive config: no commit can fail (mirrors Gate B's
      # same fast-path and for the identical reason — skip the chain
      # walk entirely under the zero-config default).
      :ok
    else
      page_size = Keyword.get(opts, :page_size, CommitStore.max_commit_log_limit())
      total_ceiling = Application.get_env(:commonplace, :max_authorization_walk_commits, 200_000)

      first_page = CommitStoreClient.commit_log(store, doc_uuid, limit: page_size)

      walk_pages(store, doc_uuid, first_page, nil, section_scope, cfg, page_size, total_ceiling, 0, 1)
    end
  end

  # CX-klpi held half: paged walk, mirroring Trust.walk_pages/11's shape
  # (see its comment for the prev_last/empty-page reasoning) but with
  # this module's simpler :ok-accumulator (no execute-clean cache here).
  defp walk_pages(store, doc_uuid, page, prev_last, section_scope, cfg, page_size, total_ceiling, examined, page_number) do
    examined_after = examined + length(page)

    cond do
      examined_after > total_ceiling ->
        Logger.error(
          "DefineVerbGate.authorized_to_define?: authorization walk for doc #{doc_uuid} " <>
            "exceeded the #{total_ceiling}-commit total ceiling (CX-klpi) after " <>
            "#{page_number} page(s) — treating as a runaway/adversarial chain"
        )

        {:error, {:authorization_chain_too_long, examined_after}}

      page == [] and prev_last == nil ->
        # No commits at all — pre-existing "empty chain -> :ok" convention.
        :ok

      page == [] ->
        Logger.error(
          "DefineVerbGate.authorized_to_define?: incomplete commit chain for doc " <>
            "#{doc_uuid} — commit #{prev_last.id} names parent " <>
            "#{prev_last.parent_id}, which the store does not have (CX-klpi)"
        )

        {:error, {:authorization_chain_incomplete, prev_last.id}}

      true ->
        case walk_page(page, section_scope, cfg, store) do
          :ok ->
            last_commit = List.last(page)

            cond do
              last_commit.parent_id == nil ->
                :ok

              length(page) < page_size ->
                Logger.error(
                  "DefineVerbGate.authorized_to_define?: incomplete commit chain for doc " <>
                    "#{doc_uuid} — commit #{last_commit.id} names parent " <>
                    "#{last_commit.parent_id}, which the store does not have (CX-klpi)"
                )

                {:error, {:authorization_chain_incomplete, last_commit.id}}

              true ->
                :telemetry.execute(
                  [:commonplace, :trust, :authorization_walk_paged],
                  %{page: page_number + 1, examined: examined_after},
                  %{uuid: doc_uuid, commit_id: last_commit.parent_id}
                )

                next_page = CommitStoreClient.commit_log_from(store, last_commit.parent_id, limit: page_size)

                walk_pages(
                  store,
                  doc_uuid,
                  next_page,
                  last_commit,
                  section_scope,
                  cfg,
                  page_size,
                  total_ceiling,
                  examined_after,
                  page_number + 1
                )
            end

          {:error, _} = error ->
            error
        end
    end
  end

  # Processes one page of the define-verb contributor walk. Returns `:ok`
  # if the page was consumed without denial, or `{:error, reason}` if it
  # halted on a commit that isn't authorized for any scope uuid.
  defp walk_page(page, section_scope, cfg, store) do
    Enum.reduce_while(page, :ok, fn commit, :ok ->
      cond do
        match?(%{metadata: %{kind: :genesis}}, commit) ->
          {:halt, :ok}

        authorized_for_any_scope?(commit, section_scope, cfg, store) ->
          {:cont, :ok}

        true ->
          reason = denial_reason(commit, section_scope, cfg, store)
          {:halt, {:error, {:undefined_contributor, commit.id, reason}}}
      end
    end)
  end

  defp authorized_for_any_scope?(commit, section_scope, cfg, store) do
    Enum.any?(section_scope, fn scope_uuid ->
      Trust.authorized?(commit, :define_verb, {:doc, scope_uuid}, cfg, store) == :ok
    end)
  end

  # Best-effort single reason for the error tuple: the first scope uuid's
  # denial reason (they're usually the same shape — untrusted signer,
  # capability_insufficient, expired, revoked, etc.) — good enough for a
  # denial message; the walk itself already tried every scope uuid.
  defp denial_reason(commit, [first | _], cfg, store) do
    case Trust.authorized?(commit, :define_verb, {:doc, first}, cfg, store) do
      {:error, reason} -> reason
      :ok -> :unknown
    end
  end

  defp denial_reason(_commit, [], _cfg, _store), do: :empty_section_scope
end
