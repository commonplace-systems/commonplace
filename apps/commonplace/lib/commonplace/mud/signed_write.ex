defmodule Commonplace.MUD.SignedWrite do
  @moduledoc """
  Composition helper for CX-lg06 — threads session identity (resolved
  ONCE at `PlayerSession` ingress, see that module's moduledoc) into
  every MUD verb's commit-producing calls.

  This module does NOT touch `Commonplace.Trust`, the commit store, or
  `Commonplace.Trust.Capability` — it only reads already-minted
  capability records (via `CommitStoreClient.get_capability/2`, the same
  read seam `Commonplace.MUD.Sections.auto_extend_for_new_room/3` uses)
  to pick which cert CID (if any) covers a given target doc, and builds
  the `{metadata, opts}` pair every `CommitStoreClient.create_commit/6`
  / `create_chained_commit/5` call site in the MUD needs.

  ## Cert-selection mechanism (the FLAG point from CX-lg06)

  `opts[:cert_cids]` is a flat list of capability CIDs the calling
  session's player is known to hold (resolved once, either passed at
  `PlayerSession` start or discovered via the same commit-log walk
  `Sections.auto_extend_for_new_room/3` uses — see that function's
  "candidate discovery" section for the exact mechanics and its
  documented enumeration blind spot, which applies here too: a cert
  that has never yet authored a commit on the target doc is invisible
  to log-based discovery). At write time this module does a **linear
  scan** of that list, loading each cert and checking whether the
  target uuid is in its `{:docs, uuids}` scope — first match wins. This
  is deliberately the simplest mechanism that works: sessions hold a
  handful of certs, not thousands, so an index is not warranted yet
  (mirrors the "not worth building a scope index" call `Sections`
  already made for auto-extend).

  CX-0a9a (presence-carve): if no `{:docs}` cert covers the target, a
  `{:presence, _}` cert the session holds is attached opportunistically
  as a second pass (see `find_presence_cert/2`) — `{:docs}` certs are
  tried FIRST so a zone-edit still routes to the zone-cert.

  No cert covering the target uuid → the commit still goes out signed
  (`opts[:signing_context]` alone) but with no `capability_proof` — a
  legitimate outcome, not an error: it hits `Trust.authorized?/5`'s
  branch `(b)` (not pinned, no proof) and is denied under strict+enforce
  same as an unsigned write would be, UNLESS the signer is itself a
  locally-pinned trusted identity. This module does not change that
  behavior; it only avoids fabricating a bogus proof.
  """

  alias Commonplace.Store.CommitStoreClient

  @doc """
  Build the `{metadata, commit_opts}` pair for a commit landing on
  `target_uuid`, given the caller's `opts`:

    * `:store` — default `CommitStoreClient`.
    * `:signing_context` — a `%Commonplace.Crypto.SigningContext{}` or
      `nil`. `nil` (the anonymous/keyless default) reproduces today's
      unsigned behavior exactly: empty metadata, empty commit opts.
    * `:cert_cids` — list of capability CIDs the session holds (default
      `[]`).
    * `:via_verb` (CX-ndvi §1.2/§2) — when present, merged into the
      commit metadata as `%{via_verb: value}` — the causal-audit tag a
      `Commonplace.MUD.World.Facade` write attaches (`{verb_doc_ref,
      owner}`) so a verb-mediated commit is distinguishable from a
      player's direct edit in the same audit trail. Absent by every
      existing caller (moves/writes issued directly by `Verbs`/`World`
      never set this) — additive, no behavior change for anyone who
      doesn't pass it.

  Returns `{metadata, commit_opts}` ready to splice into
  `CommitStoreClient.create_commit/6` (metadata as the 5th positional
  arg) or `create_chained_commit/5` (metadata as the 4th positional
  arg); `commit_opts` is the trailing `opts` keyword list either way.
  """
  @spec opts_for(String.t() | nil, keyword()) :: {map(), keyword()}
  def opts_for(target_uuid, opts \\ [])

  def opts_for(target_uuid, opts) do
    case Keyword.get(opts, :signing_context) do
      nil ->
        {via_verb_metadata(%{}, opts), []}

      signing_context ->
        store = Keyword.get(opts, :store, CommitStoreClient)
        cert_cids = Keyword.get(opts, :cert_cids, [])
        commit_opts = [signing_context: signing_context]

        metadata =
          case find_cert(target_uuid, cert_cids, store) do
            nil -> %{}
            cap_id -> %{kind: :regular, capability_proof: cap_id}
          end

        {via_verb_metadata(metadata, opts), commit_opts}
    end
  end

  defp via_verb_metadata(metadata, opts) do
    case Keyword.get(opts, :via_verb) do
      nil ->
        metadata

      via_verb ->
        # `Commonplace.Store.Commit.new/5` requires a `:kind` tag on any
        # non-empty metadata map — `find_cert/3` already sets `:regular`
        # when a capability_proof is attached, but the no-cert branch
        # above leaves metadata `%{}` (empty, so no :kind needed) UNTIL
        # via_verb makes it non-empty here. `Map.put_new` so an existing
        # `:kind` (the capability_proof branch) is never overwritten.
        metadata |> Map.put(:via_verb, via_verb) |> Map.put_new(:kind, :regular)
    end
  end

  @doc """
  The hand (Yjs client_id) a signed write should reconstruct/mint under:
  `WriterHand.for_doc_actor(doc_uuid, signer_id)` when the session
  carries a `:signer_id` (keeps concurrent distinct players from
  clashing on the SAME doc's client-id slot — see `WriterHand`
  moduledoc, "Asymmetric deconfliction"), else the existing
  `WriterHand.for_doc/1` per-doc funnel hand (unsigned/anonymous
  sessions — unchanged behavior).
  """
  @spec hand_for(String.t(), keyword()) :: non_neg_integer()
  def hand_for(doc_uuid, opts \\ []) do
    case Keyword.get(opts, :signer_id) do
      nil -> Commonplace.WriterHand.for_doc(doc_uuid)
      signer_id -> Commonplace.WriterHand.for_doc_actor(doc_uuid, signer_id)
    end
  end

  defp find_cert(_target_uuid, [], _store), do: nil

  defp find_cert(target_uuid, cert_cids, store) when is_binary(target_uuid) do
    case find_docs_cert(target_uuid, cert_cids, store) do
      nil -> find_presence_cert(cert_cids, store)
      cid -> cid
    end
  end

  defp find_cert(_target_uuid, _cert_cids, _store), do: nil

  defp find_docs_cert(target_uuid, cert_cids, store) do
    Enum.find_value(cert_cids, fn cid ->
      case CommitStoreClient.get_capability(store, cid) do
        {:ok, %{claim: %{scope: {:docs, uuids}}}} ->
          if target_uuid in uuids, do: cid, else: nil

        _ ->
          nil
      end
    end)
  end

  # CX-0a9a (presence-carve, W5): no {:docs} cert covers the target —
  # opportunistically attach a held {:presence, _} cert instead. This is
  # safe WITHOUT checking the target here: the presence cert is
  # CONTENT-GATED at verify time (`Commonplace.Trust.grants?/5`'s
  # presence clause, backed by the `presence_carve_ok?/4` check) — if
  # the write isn't actually this identity's own presence entry, the
  # gate refuses it there. Attaching it speculatively never over-grants;
  # it only gives a legitimate own-presence write somewhere to prove
  # its authority. {:docs} certs are tried FIRST (see `find_cert/3`) so
  # a zone-edit still routes to the zone-cert, never to this fallback.
  defp find_presence_cert(cert_cids, store) do
    Enum.find_value(cert_cids, fn cid ->
      case CommitStoreClient.get_capability(store, cid) do
        {:ok, %{claim: %{scope: {:presence, _id}}}} -> cid
        _ -> nil
      end
    end)
  end
end
