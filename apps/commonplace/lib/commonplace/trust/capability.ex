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

    with :ok <- check_attenuation(claim, opts[:parent]) do
      cap = new(issuer, audience, claim, parent_cid) |> sign(issuer_ctx.private_key)
      {:ok, cap}
    end
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
