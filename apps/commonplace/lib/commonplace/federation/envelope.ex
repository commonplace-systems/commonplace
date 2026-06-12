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
  """

  alias Commonplace.Store.Commit
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.Capability

  @version 1
  # Mirrors Trust.VerifyChain's chain-length bound.
  @max_chain 64

  @doc """
  Encode a commit and its supporting certs into a JSON envelope binary.
  """
  @spec encode(Commit.t(), [Capability.t()]) :: binary()
  def encode(%Commit{} = commit, certs) when is_list(certs) do
    Jason.encode!(%{
      v: @version,
      commit: pack(commit),
      certs: Enum.map(certs, &pack/1)
    })
  end

  @doc """
  Build the envelope for a commit, inlining its full cert chain
  (leaf → root, following `proof` pointers, bounded like `VerifyChain`).
  Certs the local store doesn't hold are simply not inlined — the
  receiver may then defer on `:awaiting_capability`, which is its call.
  """
  @spec for_commit(GenServer.server(), Commit.t()) :: binary()
  def for_commit(store, %Commit{} = commit) do
    encode(commit, collect_chain(store, commit.metadata[:capability_proof], []))
  end

  defp collect_chain(_store, nil, acc), do: Enum.reverse(acc)
  defp collect_chain(_store, _cid, acc) when length(acc) >= @max_chain, do: Enum.reverse(acc)

  defp collect_chain(store, cid, acc) do
    case CommitStoreClient.get_capability(store, cid) do
      {:ok, %Capability{} = cert} -> collect_chain(store, cert.proof, [cert | acc])
      :none -> Enum.reverse(acc)
    end
  end

  @doc """
  Decode an envelope binary. Returns `{:ok, %{commit: commit, certs: certs}}`
  or `{:error, reason}` — never raises on untrusted input.
  """
  @spec decode(binary()) ::
          {:ok, %{commit: Commit.t(), certs: [Capability.t()]}}
          | {:error, :bad_json | :bad_payload | :unsupported_version}
  def decode(binary) when is_binary(binary) do
    with {:ok, %{"v" => @version, "commit" => commit_b64, "certs" => cert_b64s}}
         when is_list(cert_b64s) <- parse_json(binary),
         {:ok, %Commit{} = commit} <- unpack(commit_b64),
         {:ok, certs} <- unpack_certs(cert_b64s) do
      {:ok, %{commit: commit, certs: certs}}
    else
      {:ok, %{"v" => v}} when v != @version -> {:error, :unsupported_version}
      {:ok, _other_shape} -> {:error, :bad_payload}
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

  defp safe_binary_to_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    ArgumentError -> {:error, :bad_payload}
  end
end
