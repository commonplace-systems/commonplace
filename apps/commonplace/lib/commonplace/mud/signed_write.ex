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
        {%{}, []}

      signing_context ->
        store = Keyword.get(opts, :store, CommitStoreClient)
        cert_cids = Keyword.get(opts, :cert_cids, [])
        commit_opts = [signing_context: signing_context]

        metadata =
          case find_cert(target_uuid, cert_cids, store) do
            nil -> %{}
            cap_id -> %{kind: :regular, capability_proof: cap_id}
          end

        {metadata, commit_opts}
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
    Enum.find_value(cert_cids, fn cid ->
      case CommitStoreClient.get_capability(store, cid) do
        {:ok, %{claim: %{scope: {:docs, uuids}}}} ->
          if target_uuid in uuids, do: cid, else: nil

        _ ->
          nil
      end
    end)
  end

  defp find_cert(_target_uuid, _cert_cids, _store), do: nil
end
