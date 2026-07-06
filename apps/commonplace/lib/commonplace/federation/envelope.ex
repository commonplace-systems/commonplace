defmodule Commonplace.Federation.Envelope do
  @moduledoc """
  The federation wire format (federate-for-real phase C, CX-orfw).

  One envelope = one commit + the capability certs a strict receiver
  needs to verify it. Certs are inlined for availability: the receiver
  stores them BEFORE importing the commit, so `Trust.VerifyChain` finds
  the whole chain locally and the import is never deferred on a cert the
  sender already had.

  The envelope itself is versioned JSON (debuggable, evolvable); the
  commit/cert payloads travel as `base64(term_to_binary/1)` and are
  decoded with `binary_to_term([:safe])` (decision D12). Why not plain
  JSON fields: a commit's id is the SHA256 of (uuid, update, parent_id,
  METADATA) where metadata is a map with atom keys and atom values —
  a JSON round-trip re-keys it with strings and `Commit.verify_id/1`
  fails on arrival. `term_to_binary` is byte-faithful; `[:safe]` refuses
  to mint NEW atoms from untrusted bytes (every atom a legitimate
  envelope needs — `:kind`, `:regular`, `:capability_proof`, struct
  names — already exists in any commonplace node). Both v1 federation
  ends are BEAM; a cross-runtime JSON codec can be added later as a new
  envelope version behind the same endpoints.

  Trust note: this module is a CODEC, not a gate. Nothing here is
  authorization — a decoded commit still passes through
  `CommitStore.import_commit` (Gate A) and certs still verify by
  signature + chain. Decode failures reject malformed bytes early, which
  is hygiene, not security.

  ## Revocations ride the same envelope (CX-bepn, design §6)

  `for_commit/2` also inlines every KNOWN revocation record filed
  against any cert in the commit's chain (tiny — a revocation is a
  hash + a pubkey + a signature). `verify_revocations/1` is the same
  kind of pre-store hygiene as `verify_certs/1` — content address +
  signature, over the record's OWN bytes — and NOT the authority check
  (§7.6: authority is checked only inside `Trust.VerifyChain`, at
  verify time, per link, where the whole chain is in hand). A receiver
  that stores an unauthorized (stranger) revocation record wastes a few
  bytes; it is inert everywhere it is later consulted.
  """

  alias Commonplace.Store.Commit
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.Capability
  alias Commonplace.Trust.Revocation

  @version 1
  # Mirrors Trust.VerifyChain's chain-length bound.
  @max_chain 64

  # `[:safe]` refuses atoms not yet interned in THIS VM — and module
  # loading is lazy, so a fresh node that has never touched a Commit
  # would reject a perfectly valid envelope (observed live: a fresh
  # `mix run --no-start` puller had no :doc_uuid/:snapshot_parent/...).
  # This module is necessarily loaded before decode runs, so listing the
  # wire format's CLOSED atom universe here interns it deterministically.
  # Grow the list when the metadata vocabulary grows — the federation
  # demo (fresh-VM puller) is the regression guard.
  @wire_atoms [
                # Commit struct fields
                :id, :doc_uuid, :parent_id, :update, :timestamp, :signature,
                :signer_id, :metadata, :merge_parents,
                # commit metadata vocabulary
                :kind, :regular, :snapshot, :merge, :genesis,
                :snapshot_parent, :capability_proof, :derivation_map,
                # Capability struct fields + claim vocabulary
                :issuer, :audience, :claim, :proof, :sig,
                :verbs, :scope, :caveats, :not_before, :not_after, :docs,
                :write, :execute, :delegate,
                # Revocation struct fields (CX-bepn)
                :revoked_cid, :revoker_pubkey,
                # DateTime fields (commit timestamps)
                :year, :month, :day, :hour, :minute, :second, :microsecond,
                :time_zone, :zone_abbr, :utc_offset, :std_offset, :calendar
              ]

  @doc "The closed atom universe of the wire format (interned at module load)."
  def wire_atoms, do: @wire_atoms

  @doc """
  Encode a commit, its supporting certs, and any known revocations
  (design §6; `revocations` defaults to `[]` so existing 2-arity call
  sites are unaffected) into a JSON envelope binary.
  """
  @spec encode(Commit.t(), [Capability.t()], [Revocation.t()]) :: binary()
  def encode(%Commit{} = commit, certs, revocations \\ [])
      when is_list(certs) and is_list(revocations) do
    Jason.encode!(%{
      v: @version,
      commit: pack(commit),
      certs: Enum.map(certs, &pack/1),
      revocations: Enum.map(revocations, &pack/1)
    })
  end

  @doc """
  Build the envelope for a commit, inlining its full cert chain
  (leaf → root, following `proof` pointers, bounded like `VerifyChain`)
  AND every known revocation filed against any cert in that chain
  (design §6 — revocations ride the same envelope/import path as
  certs). Certs/revocations the local store doesn't hold are simply not
  inlined — the receiver may then defer on `:awaiting_capability` (for a
  missing cert), which is its call.
  """
  @spec for_commit(GenServer.server(), Commit.t()) :: binary()
  def for_commit(store, %Commit{} = commit) do
    chain = collect_chain(store, commit.metadata[:capability_proof], [])
    encode(commit, chain, collect_revocations(store, chain))
  end

  defp collect_chain(_store, nil, acc), do: Enum.reverse(acc)
  defp collect_chain(_store, _cid, acc) when length(acc) >= @max_chain, do: Enum.reverse(acc)

  defp collect_chain(store, cid, acc) do
    case CommitStoreClient.get_capability(store, cid) do
      {:ok, %Capability{} = cert} -> collect_chain(store, cert.proof, [cert | acc])
      :none -> Enum.reverse(acc)
    end
  end

  defp collect_revocations(store, chain) do
    chain
    |> Enum.flat_map(&CommitStoreClient.get_revocations(store, &1.id))
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Decode an envelope binary. Returns
  `{:ok, %{commit: commit, certs: certs, revocations: revocations}}` or
  `{:error, reason}` — never raises on untrusted input. `"revocations"`
  is optional in the wire JSON (absent ⇒ `[]`) so envelopes written
  before CX-bepn (e.g. archived `git_bridge` rows) still decode.
  """
  @spec decode(binary()) ::
          {:ok, %{commit: Commit.t(), certs: [Capability.t()], revocations: [Revocation.t()]}}
          | {:error, :bad_json | :bad_payload | :unsupported_version}
  def decode(binary) when is_binary(binary) do
    with {:ok, %{"v" => @version, "commit" => commit_b64, "certs" => cert_b64s} = map}
         when is_list(cert_b64s) <- parse_json(binary),
         revocation_b64s <- Map.get(map, "revocations", []),
         true <- is_list(revocation_b64s),
         {:ok, %Commit{} = commit} <- unpack(commit_b64),
         {:ok, certs} <- unpack_certs(cert_b64s),
         {:ok, revocations} <- unpack_revocations(revocation_b64s) do
      {:ok, %{commit: commit, certs: certs, revocations: revocations}}
    else
      {:ok, %{"v" => v}} when v != @version -> {:error, :unsupported_version}
      {:ok, _other_shape} -> {:error, :bad_payload}
      false -> {:error, :bad_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_json(binary) do
    case Jason.decode(binary) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :bad_json}
    end
  end

  defp pack(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  defp unpack(b64) when is_binary(b64) do
    with {:ok, bytes} <- Base.decode64(b64),
         {:ok, term} <- safe_binary_to_term(bytes) do
      case term do
        %Commit{} -> {:ok, term}
        %Capability{} -> {:ok, term}
        %Revocation{} -> {:ok, term}
        _ -> {:error, :bad_payload}
      end
    else
      :error -> {:error, :bad_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unpack(_), do: {:error, :bad_payload}

  defp unpack_certs(b64s) do
    Enum.reduce_while(b64s, {:ok, []}, fn b64, {:ok, acc} ->
      case unpack(b64) do
        {:ok, %Capability{} = cert} -> {:cont, {:ok, [cert | acc]}}
        {:ok, _not_a_cert} -> {:halt, {:error, :bad_payload}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, certs} -> {:ok, Enum.reverse(certs)}
      err -> err
    end
  end

  defp unpack_revocations(b64s) do
    Enum.reduce_while(b64s, {:ok, []}, fn b64, {:ok, acc} ->
      case unpack(b64) do
        {:ok, %Revocation{} = rev} -> {:cont, {:ok, [rev | acc]}}
        {:ok, _not_a_revocation} -> {:halt, {:error, :bad_payload}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, revocations} -> {:ok, Enum.reverse(revocations)}
      err -> err
    end
  end

  defp safe_binary_to_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> {:error, :bad_payload}
  end

  @doc """
  Verify that every inlined cert is a self-consistent value (content
  address matches, issuer signature verifies) BEFORE it is stored.
  Early hygiene against cert-store bloat — NOT the authority check
  (that's `VerifyChain`, at import time, anchored to local pins).
  """
  @spec verify_certs([Capability.t()]) :: :ok | {:error, :invalid_cert}
  def verify_certs(certs) do
    if Enum.all?(certs, fn %Capability{} = c ->
         Capability.verify_id(c) == :ok and Capability.verify_sig(c) == :ok
       end) do
      :ok
    else
      {:error, :invalid_cert}
    end
  end

  @doc """
  Verify that every inlined revocation record is self-consistent
  (content address matches, signature verifies against its OWN declared
  `revoker_pubkey`) BEFORE it is stored. Same arrival-time hygiene as
  `verify_certs/1`, and just as deliberately NOT an authority check
  (design §7.6): whether the revoker actually has revocation authority
  over the cert it names can only be validated at verify time, against
  the full chain — see `Commonplace.Trust.Revocation`'s moduledoc for
  why validating authority here would DROP early-arriving revocations.
  """
  @spec verify_revocations([Revocation.t()]) :: :ok | {:error, :invalid_revocation}
  def verify_revocations(revocations) do
    if Enum.all?(revocations, fn %Revocation{} = r ->
         Revocation.verify_id(r) == :ok and Revocation.verify_sig(r) == :ok
       end) do
      :ok
    else
      {:error, :invalid_revocation}
    end
  end
end
