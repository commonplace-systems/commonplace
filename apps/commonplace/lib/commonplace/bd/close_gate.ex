defmodule Commonplace.Bd.CloseGate do
  @moduledoc """
  Bd P2 Slice S3 — the `done_when` witness validators. `ticket_close`
  (`Commonplace.ViewActionDispatch`) hands this module the ticket's
  pre-declared `done_when` plus a list of CLIENT-SUPPLIED CANDIDATE
  proof cids (hex strings) — the client proposes proofs, it never gets
  to name requirements; the requirement is whatever `done_when` already
  says, read off the ticket, not off the close call.

  `validate_witnesses/4` returns `{:ok, done_witness_list}` (the value
  to write into `Issue.done_witness`) or a SANITIZED `{:error, string}`
  — no raw trust-decision tuple (`{:untrusted_signer, _}` etc.) ever
  reaches a caller, matching the sanitization discipline
  `ViewActionDispatch.sanitize_write_error/1` already applies to
  `pr_accept`'s refusals.

  ## v1 validators (dispatch plug-point)

  Only two `done_when` types exist in v1 — `"manual"` and
  `%{"type" => "pr_merge", "target" => uuid}`. A future type
  (`sign_off`, `ci_green`, `artifact`, ...) adds a new
  `validate_witnesses/4` head here; the catch-all clause below refuses
  anything unrecognized rather than silently falling through to
  "no witness required."

    * **manual** — no extra witness. The signed `ticket_close` commit
      IS the proof (invoker-signed + write-gated, same as every other
      ticket write). `done_witness` stays `[]`.
    * **pr_merge** — the FIRST candidate cid that satisfies ALL FOUR of
      `valid_pr_merge_witness?/3`'s checks becomes the sole witness.

  ## The pr_merge stamp — why "authorized commit landed on target" isn't enough

  `valid_pr_merge_witness?/3` checks, in order: (1) the cid **exists**
  in the store: (2) it is **on the declared target's own chain**
  (`commit_ids_for_doc`) — the target comes from `done_when["target"]`,
  a value the TICKET carries, never a client-supplied close arg; (3) it
  is **signed**, and its signer holds **target-write authority**,
  RE-DERIVED AT VERIFY TIME via `Trust.writer_authorized?/6` — the SAME
  commitless predicate `ViewActionDispatch`'s `pr_accept` step 4 uses,
  pointed at the WITNESS COMMIT's signer instead of a live acceptor.
  **Authority-surface congruence (v1, cp-plan ⛩).** The call passes
  `cert_cids: []` and `pub: nil` — mirroring `pr_accept`'s OWN step-4,
  which also passes `cert_cids: []` (this wiki/PR surface carries no
  citizenship-cert plumbing). The load-bearing consequence: under enforce,
  ONLY a trusted-identity acceptor can accept a PR at all today, so a
  citizen-cert-signed merge commit CANNOT be minted — the witness
  validator refusing what cannot exist is ALIGNMENT, not a narrowing. The
  invariant to preserve: witness-authority-surface ==
  pr_accept-authority-surface; the two move TOGETHER. When cert_cids
  threading reaches this surface (the follow-up slice), BOTH move at once
  and citizen-witnessed completion — the design's proof-carrying `witness`
  bundle (acceptor pubkey + cert @-refs embedded in the stamp, authority
  re-derived from the carried chain, no circularity because the embedded
  pubkey is checked against the signature) — lights up on both.

  **Mandatory verify-time re-derivation.** Authority is necessary but NOT
  sufficient: `writer_authorized?` is a commitless pre-check that assumes
  signature validity "by construction" (true of a live signer, false of a
  stored commit we re-examine), so the validator ALSO cryptographically
  verifies the commit's signature against a key it independently pins for
  the signer (`signature_verifies_against_pinned?`, resolved from
  `trusted_identities`, NEVER from the commit). It judges the artifact by
  its own cryptography, not by the store's admission history —
  `signed?`-presence alone is a real hole under permissive configs where
  on-chain ≠ verified. Because this is verify-TIME, revoking a signer
  afterward retroactively invalidates witnesses they signed — coherent
  policy (CX-bepn), not a bug: the ticket cannot stay closed on the word
  of someone whose authority was pulled.
  (4) the commit's `metadata` carries the **pr-provenance stamp**
  (`metadata[:pr_merge]`, stamped by `ViewActionDispatch.do_accept_merge/7`
  — see `Commonplace.Tree.Merge`'s moduledoc for the plumb). This LAST
  check is the one that closes the semantic gap: (1)+(2)+(3) alone only
  prove "SOME commit, authorized to write the target, landed on the
  target's chain" — not that it was a PR MERGE that landed. Anyone with
  target-write authority can land an ordinary edit; without the stamp
  requirement an ordinary authorized edit would satisfy a `pr_merge`
  close just as well as an actual accepted PR, which is not what
  `done_when: pr_merge` is supposed to mean. The stamp lives INSIDE the
  signed commit's `metadata`, which is content-addressed
  (`Commonplace.Store.Commit.content_address/4`) — so it is bound into
  the commit id and covered by the signer's signature over that id:
  unforgeable without the signer's key, and it needs NO trust in the
  (editable, non-authoritative) PR doc's own recorded status.
  """

  alias Commonplace.Crypto.Signing
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust

  @doc """
  Resolves `done_when` + caller-supplied candidate witness cids (hex
  strings) into the `done_witness` list to write, or a sanitized
  refusal. `root_uuid` is threaded for future done_when types that may
  need it (unused by the two v1 validators); `store` defaults to
  `CommitStoreClient`, matching every other Bd chokepoint.
  """
  @spec validate_witnesses(String.t() | map(), [String.t()], String.t(), module() | atom()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def validate_witnesses(done_when, candidates, root_uuid, store \\ CommitStoreClient)

  def validate_witnesses("manual", _candidates, _root_uuid, _store), do: {:ok, []}

  def validate_witnesses(%{"type" => "pr_merge", "target" => target}, candidates, _root_uuid, store)
      when is_binary(target) and is_list(candidates) do
    case Enum.find(candidates, &valid_pr_merge_witness?(&1, target, store)) do
      nil ->
        {:error,
         "no candidate witness satisfies the pr_merge requirement for this ticket's declared target"}

      cid_hex ->
        {:ok, [cid_hex]}
    end
  end

  def validate_witnesses(_done_when, _candidates, _root_uuid, _store) do
    {:error, "ticket has an unsupported done_when — cannot close"}
  end

  ## --- pr_merge witness validation ---

  defp valid_pr_merge_witness?(cid_hex, target, store) when is_binary(cid_hex) do
    cfg = Trust.config()

    with {:ok, cid} <- decode_cid(cid_hex),
         {:ok, commit} <- fetch_commit(store, cid),
         true <- on_target_chain?(store, target, cid),
         true <- Signing.signed?(commit),
         {:ok, identity_uuid, _fingerprint} <- Signing.parse_signer_id(commit.signer_id || ""),
         true <- Trust.writer_authorized?(identity_uuid, nil, [], target, cfg, store),
         true <- signature_verifies_against_pinned?(commit, identity_uuid, cfg),
         true <- Map.has_key?(commit.metadata, :pr_merge) do
      true
    else
      _ -> false
    end
  end

  defp valid_pr_merge_witness?(_cid_hex, _target, _store), do: false

  # MANDATORY verify-time re-derivation (cp-plan ⛩ ruling): authority
  # (`writer_authorized?` above) is necessary but NOT sufficient — it is a
  # commitless pre-check that assumes signature validity "by construction"
  # (true when a LIVE signer signs, false of a STORED commit we are
  # re-examining). So the validator judges the artifact by its OWN
  # cryptography: the commit's signature must verify against a key we
  # independently pin for its signer, resolved from the trust config's
  # `trusted_identities` and NEVER from the commit itself (a `signer_id`
  # carries only an 8-byte fingerprint — a commit cannot vouch for its own
  # key). This is not trusting the store's admission history: `signed?`
  # presence alone is a real hole under permissive configs, where on-chain
  # ≠ verified. A signer with no pinned key (only reachable via
  # `accept_unsigned`) has nothing to verify against → refused. Mirrors
  # the private `Commonplace.Trust.verify_against_pinned/2`.
  defp signature_verifies_against_pinned?(commit, identity_uuid, cfg) do
    case Map.get(cfg.trusted_identities, identity_uuid) do
      nil ->
        false

      pinned ->
        pinned
        |> List.wrap()
        |> Enum.any?(fn encoded ->
          case Signing.decode_key(encoded) do
            {:ok, key} -> Signing.verify_commit(commit, key) == :ok
            {:error, _} -> false
          end
        end)
    end
  end

  defp decode_cid(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp fetch_commit(store, cid) do
    case CommitStoreClient.get_commit(store, cid) do
      {:ok, commit} -> {:ok, commit}
      :none -> :error
    end
  end

  defp on_target_chain?(store, target, cid) do
    MapSet.member?(CommitStoreClient.commit_ids_for_doc(store, target), cid)
  end
end
