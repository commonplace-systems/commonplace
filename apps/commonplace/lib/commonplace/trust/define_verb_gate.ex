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
  `{:verb, _}` gate re-walks the full contributor chain (bounded by the
  same `commit_log(..., limit: 10_000)` ceiling Gate B uses). Correct,
  not yet optimized — flagged in the CX-ndvi completion report.
  """

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust

  @doc """
  Is every commit contributing to `doc_uuid`'s state authorized for
  `:define_verb` over at least one uuid in `section_scope`?

  Returns `:ok` or `{:error, {:undefined_contributor, commit_id, reason}}`.
  An empty chain (doc not found / no commits) returns `:ok` — same
  convention as `authorized_to_execute?/3`; the caller's own read fails
  with `:not_found` independently.
  """
  @spec authorized_to_define?(GenServer.server(), String.t(), [String.t()], Trust.config() | nil) ::
          :ok | {:error, term()}
  def authorized_to_define?(store, doc_uuid, section_scope, cfg \\ nil)
      when is_list(section_scope) do
    cfg = cfg || Trust.config()

    if cfg.accept_unsigned and cfg.trusted_identities == %{} do
      # Fully-permissive config: no commit can fail (mirrors Gate B's
      # same fast-path and for the identical reason — skip the chain
      # walk entirely under the zero-config default).
      :ok
    else
      log = CommitStoreClient.commit_log(store, doc_uuid, limit: 10_000)
      walk(store, log, section_scope, cfg)
    end
  end

  defp walk(store, log, section_scope, cfg) do
    Enum.reduce_while(log, :ok, fn commit, :ok ->
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
