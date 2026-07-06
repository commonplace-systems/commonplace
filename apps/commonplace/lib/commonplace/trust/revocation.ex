defmodule Commonplace.Trust.Revocation do
  @moduledoc """
  A revocation record (CX-bepn, phase 3 follow-on): a content-addressed,
  signed statement that a capability cert is void. See
  docs/plans/2026-07-06-capability-revocation-design.md §1-§3, §7.6.

      %Revocation{
        revoked_cid: cap.id,          # the cert being revoked
        revoker_pubkey: <32 bytes>,   # who says so
        sig: <Ed25519 over the canonical encoding>,
      }
      id = hash(revoked_cid <> revoker_pubkey)   # content-addressed, dedupes

  ## Arrival vs verify (§7.6 — the load-bearing rule)

  Federation makes no ordering promise: a revocation can arrive BEFORE
  the cert it revokes, and revoker AUTHORITY (§2: issuer on the revoked
  cert's proof path, or the revoked cert's own audience) cannot be
  checked without that cert's chain in hand. This module therefore only
  ever validates a record's OWN internal consistency —
  `verify_id/1` (content address) and `verify_sig/1` (the revoker's
  signature over its own id) — both checkable from the record's own
  bytes, at arrival time. Authority is checked ONLY inside
  `Commonplace.Trust.VerifyChain`, per link, at VERIFY time, where the
  full chain is available and path-membership is free to compute. An
  implementation that validated authority at import/arrival would DROP
  an early-arriving revocation (the cert it targets isn't stored yet, so
  no path exists to check against) and the revoked cert would silently
  resurrect once it landed — precisely the failure this split prevents.
  Records are cheap and harmless to store unvalidated-for-authority:
  `Trust.VerifyChain` treats a revocation from a signer with no path
  membership as inert (naturally, since the path-membership test simply
  never matches), with a telemetry counter kept on ignored records.

  ## Eventual revocation / expiry-permanent (§6)

  Absence-of-revocation is not provable over an async network — this is
  accepted, not "fixed": revocation delivers intent fast once it's
  heard, and short `not_after` caveats remain **permanent policy, not an
  interim hack** for bounding the worst case on a peer that never hears
  it (the CRL-gossip + short-lived-certs stance). Nothing in this module
  carries a timestamp of its own (P1, §3): a revocation has no
  "valid-when-signed" carve-out — revocation-record times aren't
  trustworthy and the complexity buys unsoundness, not safety.
  """

  @type t :: %__MODULE__{
          revoked_cid: binary(),
          revoker_pubkey: binary(),
          sig: binary() | nil,
          id: binary()
        }

  defstruct [:revoked_cid, :revoker_pubkey, :sig, :id]

  @doc """
  Mint an unsigned revocation record with its CID computed
  (`hash(revoked_cid <> revoker_pubkey)` — content-addressed, so the
  same revoker revoking the same cert twice dedupes to the same id).
  """
  @spec new(binary(), binary()) :: t()
  def new(revoked_cid, revoker_pubkey)
      when is_binary(revoked_cid) and is_binary(revoker_pubkey) do
    %__MODULE__{
      revoked_cid: revoked_cid,
      revoker_pubkey: revoker_pubkey,
      sig: nil,
      id: content_address(revoked_cid, revoker_pubkey)
    }
  end

  @doc "Re-hash and compare to the claimed `id`."
  @spec verify_id(t()) :: :ok | {:error, {:id_mismatch, binary(), binary()}}
  def verify_id(%__MODULE__{} = rev) do
    computed = content_address(rev.revoked_cid, rev.revoker_pubkey)
    if computed == rev.id, do: :ok, else: {:error, {:id_mismatch, computed, rev.id}}
  end

  @doc "Sign the record's id with the revoker's Ed25519 private key."
  @spec sign(t(), binary()) :: t()
  def sign(%__MODULE__{} = rev, private_key) when is_binary(private_key) do
    sig = :crypto.sign(:eddsa, :none, rev.id, [private_key, :ed25519])
    %{rev | sig: sig}
  end

  @doc """
  Verify the record's signature against its OWN declared
  `revoker_pubkey` — internal consistency only (§7.6: NOT an authority
  check; that is `VerifyChain`'s job, at verify time, per-link).
  """
  @spec verify_sig(t()) :: :ok | {:error, :unsigned | :invalid_signature}
  def verify_sig(%__MODULE__{sig: nil}), do: {:error, :unsigned}

  def verify_sig(%__MODULE__{revoker_pubkey: pubkey} = rev) do
    case :crypto.verify(:eddsa, :none, rev.id, rev.sig, [pubkey, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end

  # Content address: sha256(revoked_cid <> revoker_pubkey), excluding sig
  # (same "sig covers the id, id excludes the sig" shape as Capability).
  defp content_address(revoked_cid, revoker_pubkey) do
    :crypto.hash(:sha256, revoked_cid <> revoker_pubkey)
  end
end
