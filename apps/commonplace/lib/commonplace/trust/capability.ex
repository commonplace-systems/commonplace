defmodule Commonplace.Trust.Capability do
  @moduledoc """
  A capability cert (CX-tdkq.22a, phase 3): a UCAN-shaped, issuer-signed,
  content-addressed delegation. The attenuation unit of the trust system —
  "identity A delegates to identity B the capability {verbs, scope,
  caveats}, as an attenuation of A's own authority (proof = parent cert
  CID), signed by A."

  ## A cert is a VALUE, pinned by CID — not live state

  Like `Commonplace.Store.Commit`, the `id` is the SHA-256 of the cert's
  load-bearing fields, *excluding* the signature — so a signature over the
  id transitively covers every meaningful field, and two nodes that mint
  the same cert converge on the same CID. The verifier treats a cert as
  immutable bytes addressed by its CID, never as "the latest state of a
  doc" (that would reopen the peer-writable-trust-state hole). Supersession
  is a *new* cert, never an edit.

  ## Full-pubkey binding (load-bearing)

  `issuer` and `audience` each carry the **full 32-byte Ed25519 public
  key**, not a fingerprint. The 8-char `signer_id` fingerprint
  (`sha256(pubkey)[0:8]` = 32 bits) is second-preimage forgeable in ~2^32
  keygens, so it can never be the cryptographic binding. The chain
  self-verifies by exact-bytes `child.issuer.pubkey == parent.audience.pubkey`
  (in `verify_chain`, CX-tdkq.22c); only the root key is anchored locally.

  ## Canonical encoding / CID determinism

  `verbs` and the `{:docs, [uuid]}` scope are normalized at `new/4` to
  **sorted, de-duplicated lists** (a `MapSet` is the runtime rep for subset
  checks, never the wire/CID contract), and the whole assertion is hashed
  via `:erlang.term_to_binary(_, [:deterministic])`. So order and
  duplicates don't change the CID.

  ## Shape

      %Capability{
        issuer:   {identity_uuid, pubkey},   # signs THIS cert
        audience: {identity_uuid, pubkey},   # delegated-to key (next issuer / commit signer)
        claim:    %{verbs: [atom], scope: {:docs, [uuid]}, caveats: %{not_before, not_after}},
        proof:    parent_cid | nil,          # nil only at a root cert
        sig:      <Ed25519 over id> | nil,
        id:       <CID>
      }
  """

  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Trust.Revocation

  @type keyed_identity :: {String.t(), binary()}
  @type claim :: %{
          verbs: [atom()],
          scope: {:docs, [String.t()]},
          caveats: %{optional(:not_before) => DateTime.t() | nil, optional(:not_after) => DateTime.t() | nil}
        }

  defstruct [:issuer, :audience, :claim, :proof, :sig, :id]

  @type t :: %__MODULE__{
          issuer: keyed_identity(),
          audience: keyed_identity(),
          claim: claim(),
          proof: binary() | nil,
          sig: binary() | nil,
          id: binary()
        }

  @doc """
  Mint an unsigned cert with its CID computed. `claim` is normalized
  (verbs + scope sorted/de-duplicated) so the CID is order-independent.
  """
  @spec new(keyed_identity(), keyed_identity(), claim(), binary() | nil) :: t()
  def new(issuer, audience, claim, proof \\ nil) do
    claim = normalize_claim(claim)
    id = content_address(issuer, audience, claim, proof)
    %__MODULE__{issuer: issuer, audience: audience, claim: claim, proof: proof, sig: nil, id: id}
  end

  @doc "Re-hash and compare to the claimed `id`."
  @spec verify_id(t()) :: :ok | {:error, {:id_mismatch, binary(), binary()}}
  def verify_id(%__MODULE__{} = cap) do
    computed = content_address(cap.issuer, cap.audience, normalize_claim(cap.claim), cap.proof)
    if computed == cap.id, do: :ok, else: {:error, {:id_mismatch, computed, cap.id}}
  end

  @doc "Sign the cert's id with the issuer's Ed25519 private key."
  @spec sign(t(), binary()) :: t()
  def sign(%__MODULE__{} = cap, private_key) when is_binary(private_key) do
    sig = :crypto.sign(:eddsa, :none, cap.id, [private_key, :ed25519])
    %{cap | sig: sig}
  end

  @doc """
  Verify the cert's signature against its declared `issuer` pubkey
  (the cert is self-describing; chain-binding to the parent is
  `verify_chain`'s job).
  """
  @spec verify_sig(t()) :: :ok | {:error, :unsigned | :invalid_signature}
  def verify_sig(%__MODULE__{sig: nil}), do: {:error, :unsigned}

  def verify_sig(%__MODULE__{issuer: {_uuid, pubkey}} = cap) do
    case :crypto.verify(:eddsa, :none, cap.id, cap.sig, [pubkey, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end

  @doc """
  Mint and sign a cert. Root issue: `parent_cid = nil`. For a delegation,
  pass the parent struct as `opts[:parent]` to enforce
  `child.claim ⊆ parent.claim` at mint time (defense-in-depth;
  `verify_chain` re-checks). Returns `{:ok, cap}` or
  `{:error, {:not_attenuation, reason}}`.
  """
  @spec issue(SigningContext.t(), keyed_identity(), claim(), binary() | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  def issue(%SigningContext{} = issuer_ctx, audience, claim, parent_cid \\ nil, opts \\ []) do
    issuer = {issuer_ctx.identity_uuid, issuer_ctx.public_key}
    claim = normalize_claim(claim)

    with :ok <- check_mint_policy(claim, opts),
         :ok <- check_attenuation(claim, opts[:parent]) do
      cap = new(issuer, audience, claim, parent_cid) |> sign(issuer_ctx.private_key)
      {:ok, cap}
    end
  end

  @doc """
  Ergonomic alias for `issue/5` — reads as the UCAN "A delegates to B"
  operation. Root issue: `parent_cid = nil`. Delegation: pass the parent
  struct as `opts[:parent]` for mint-time narrowing validation.
  """
  @spec delegate(SigningContext.t(), keyed_identity(), claim(), binary() | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  def delegate(issuer_ctx, audience, claim, parent_cid \\ nil, opts \\ []) do
    issue(issuer_ctx, audience, claim, parent_cid, opts)
  end

  @doc """
  Mint and sign a `Commonplace.Trust.Revocation` (CX-bepn, design §1/§8
  step 5): `revoker_ctx` says "the cert at `revoked_cid` is void." No
  authority check happens here — by design (§7.6): whether this signer
  actually HAS revocation authority over `revoked_cid` (path-issuer or
  the cert's own audience) can only be checked against the cert's chain,
  which may not even be locally known yet at mint time. `VerifyChain`
  validates authority per-link, at verify time. This function is
  intentionally infallible (mirrors the shape of `issue/5`'s return for
  API consistency, even though minting a revocation never fails).
  """
  @spec revoke(SigningContext.t(), binary()) :: {:ok, Revocation.t()}
  def revoke(%SigningContext{} = revoker_ctx, revoked_cid) when is_binary(revoked_cid) do
    rev =
      revoked_cid
      |> Revocation.new(revoker_ctx.public_key)
      |> Revocation.sign(revoker_ctx.private_key)

    {:ok, rev}
  end

  @doc """
  Is `child` a valid attenuation of `parent` — verbs ⊆, scope ⊆, and the
  caveat window no wider? Public so `verify_chain` reuses it per link.
  """
  @spec attenuates?(claim(), claim()) :: boolean()
  def attenuates?(child, parent) do
    child = normalize_claim(child)
    parent = normalize_claim(parent)

    verbs_ok = MapSet.subset?(MapSet.new(child.verbs), MapSet.new(parent.verbs))
    scope_ok = MapSet.subset?(scope_set(child.scope), scope_set(parent.scope))
    caveats_ok = caveat_window_within?(child.caveats, parent.caveats)
    verbs_ok and scope_ok and caveats_ok
  end

  # --- private ---

  # CX-tdkq.28 — interim, defense-in-depth: refuse minting a :write-without-:execute
  # cert scoped to a doc that *looks like* code (best-effort, CodeDocHeuristic). A
  # write-only cert on a code doc is the LAUNDERING INPUT: a peer lands code bytes
  # under :write that a later node-signed snapshot can absorb into the execute
  # baseline. Closing it at mint stops the input; CX-tdkq.27 is the airtight backstop
  # for when this heuristic misses. Override: opts[:allow_write_without_execute].
  defp check_mint_policy(claim, opts) do
    verbs = MapSet.new(claim.verbs)
    write_without_execute? = MapSet.member?(verbs, :write) and not MapSet.member?(verbs, :execute)

    cond do
      not write_without_execute? -> :ok
      opts[:allow_write_without_execute] -> :ok
      true -> check_no_code_doc_in_scope(claim.scope, opts)
    end
  end

  defp check_no_code_doc_in_scope({:docs, uuids}, opts) do
    store = opts[:store] || Commonplace.Store.CommitStoreClient

    case Enum.find(uuids, &Commonplace.Trust.CodeDocHeuristic.code_doc?(&1, store)) do
      nil -> :ok
      uuid -> {:error, {:write_without_execute_on_code_doc, uuid}}
    end
  end

  defp check_attenuation(_claim, nil), do: :ok

  defp check_attenuation(claim, %__MODULE__{claim: parent_claim}) do
    if attenuates?(claim, parent_claim),
      do: :ok,
      else: {:error, {:not_attenuation, :child_exceeds_parent}}
  end

  defp normalize_claim(claim) do
    %{
      verbs: claim |> Map.get(:verbs, []) |> Enum.uniq() |> Enum.sort(),
      scope: normalize_scope(Map.get(claim, :scope, {:docs, []})),
      caveats: normalize_caveats(Map.get(claim, :caveats, %{}))
    }
  end

  defp normalize_scope({:docs, uuids}), do: {:docs, uuids |> Enum.uniq() |> Enum.sort()}

  defp normalize_caveats(caveats) do
    %{not_before: Map.get(caveats, :not_before), not_after: Map.get(caveats, :not_after)}
  end

  defp scope_set({:docs, uuids}), do: MapSet.new(uuids)

  # The child window must sit inside the parent window: child can only
  # start later (not_before ≥ parent) and end earlier (not_after ≤ parent).
  # nil = unbounded on that side.
  defp caveat_window_within?(child, parent) do
    not_before_ok =
      case {child.not_before, parent.not_before} do
        {_c, nil} -> true
        {nil, _p} -> false
        {c, p} -> not before?(c, p)
      end

    not_after_ok =
      case {child.not_after, parent.not_after} do
        {_c, nil} -> true
        {nil, _p} -> false
        {c, p} -> not after?(c, p)
      end

    not_before_ok and not_after_ok
  end

  defp before?(a, b), do: DateTime.compare(a, b) == :lt
  defp after?(a, b), do: DateTime.compare(a, b) == :gt

  # Content address: sha256 over the canonical assertion, excluding sig.
  defp content_address(issuer, audience, claim, proof) do
    canonical =
      :erlang.term_to_binary(
        {issuer, audience, canonical_claim(claim), proof || <<>>},
        [:deterministic]
      )

    :crypto.hash(:sha256, canonical)
  end

  # Claim canonicalized to sorted lists (already normalized at new/4, but
  # re-applied so verify_id is robust against a hand-built struct).
  defp canonical_claim(claim) do
    {:docs, uuids} = normalize_scope(claim.scope)
    {Enum.sort(Enum.uniq(claim.verbs)), {:docs, uuids}, normalize_caveats(claim.caveats)}
  end
end
