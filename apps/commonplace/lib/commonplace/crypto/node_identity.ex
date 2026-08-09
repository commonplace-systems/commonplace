defmodule Commonplace.Crypto.NodeIdentity do
  @moduledoc """
  The workspace's **node signing identity** (CX-tdkq.24, trust phase 2.5).

  System-minted commits — snapshots (the lazy/auto-snapshot worker) and
  merge commits (`SiblingMerger` / `CrossEpochMerge`) — are born without
  a user `SigningContext`. Under strict mode (`accept_unsigned: false`)
  that makes them landmines: an unsigned auto-snapshot on a code doc
  bricks its executability at Gate B, and an unsigned merge is rejected
  at Gate A. The fix is to give those commits an **accountable signer**
  that is not a peer: the node itself.

  This module mints (on first use) and reads a per-workspace Ed25519
  keypair, stored under the workspace `data_dir` exactly like `node_id`
  and the SecretStore — **local, never synced, not peer-writable**, so it
  is a valid trust anchor. The signing identity is the workspace
  `node_id` (`Commonplace.Workspace.node_id/0`), so a node's system
  commits trace to that node.

  `Commonplace.Trust` auto-trusts this identity (the node trusts its own
  commits by construction — its private key is local-only and a peer
  cannot forge it), so a single-node strict workspace works with zero
  configuration. Multi-node strict clusters must additionally pin each
  peer node's public key (or, in phase 3, accept a root-issued
  attestation of node keys) — that cross-pinning is the documented gap,
  not a blocker for the single-node target.

  ## Determinism note

  A signature lives **outside** a commit's content address (see
  `Commonplace.Store.Commit`), so node-signing a snapshot or merge does
  not change its id. Two nodes that independently mint the same
  deterministic snapshot/merge still converge on the same id (and the
  CAS write dedups them); they merely record different signers, which is
  fine — each is an accountable node-local signer.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore

  @key_file "node_signing_key"
  @public_keys_file "node_signing_public_keys.json"

  @doc """
  Return the node's `%SigningContext{}`, minting the keypair on genuine
  first use. If the key is absent after a prior world existed, refuses
  to mint a replacement identity. Callers treat errors as "no node signer
  available" and fall back to leaving the commit unsigned.
  """
  @spec signing_context() :: {:ok, SigningContext.t()} | {:error, term()}
  def signing_context do
    with {:ok, identity} <- Commonplace.Workspace.node_id(),
         {:ok, {pub, priv}} <- load_or_mint_keypair(),
         :ok <- publish_public_keys([pub]) do
      {:ok,
       %SigningContext{
         identity_uuid: identity,
         private_key: priv,
         public_key: pub
       }}
    end
  end

  @doc "The node identity's raw Ed25519 public key, read only from the public artifact."
  @spec public_key() :: {:ok, binary()} | {:error, term()}
  def public_key do
    case public_keys() do
      {:ok, [pub | _]} -> {:ok, pub}
      {:ok, []} -> {:error, :no_node_public_keys}
      :absent -> {:error, :node_public_keys_absent}
      {:error, _} = err -> err
    end
  end

  @doc """
  Read the node anchor's public-key artifact.

  `:absent` is deliberately distinct from `{:ok, []}`: the former lets
  anchor consumers fall back to their configured anchors, while the
  latter faithfully represents a present artifact declaring zero keys.
  This function never reads or creates `node_signing_key`.
  """
  @spec public_keys() :: {:ok, [binary()]} | :absent | {:error, term()}
  def public_keys do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    case File.read(Path.join(data_dir, @public_keys_file)) do
      {:ok, contents} -> decode_public_keys(contents)
      {:error, :enoent} -> :absent
      {:error, _} = err -> err
    end
  end

  @doc "The node signing identity (the workspace node_id)."
  @spec identity() :: {:ok, String.t()} | {:error, term()}
  def identity, do: Commonplace.Workspace.node_id()

  # --- key storage (mirrors Workspace.node_id's atomic-write discipline) ---

  defp load_or_mint_keypair do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    path = Path.join(data_dir, @key_file)

    case File.read(path) do
      {:ok, contents} ->
        decode_keypair(contents)

      {:error, :enoent} ->
        if CommitStore.prior_world_evidence?(data_dir) do
          {:error, {:node_signing_key_absent, :prior_world_present}}
        else
          mint_keypair(data_dir, path)
        end

      {:error, _} = err ->
        err
    end
  end

  # Stored as two base64 lines: public, then private.
  defp decode_keypair(contents) do
    with [pub_b64, priv_b64 | _] <- String.split(String.trim(contents), "\n"),
         {:ok, pub} <- Base.decode64(pub_b64),
         {:ok, priv} <- Base.decode64(priv_b64) do
      {:ok, {pub, priv}}
    else
      _ -> {:error, :corrupt_node_key}
    end
  end

  defp mint_keypair(data_dir, path) do
    {pub, priv} = Signing.generate_keypair()
    contents = Base.encode64(pub) <> "\n" <> Base.encode64(priv) <> "\n"
    tmp = Path.join(data_dir, ".#{@key_file}.tmp")

    with :ok <- File.mkdir_p(data_dir),
         :ok <- File.write(tmp, contents, [:write]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path),
         {:ok, final} <- File.read(path) do
      # Re-read after rename so concurrent first-boot races settle on
      # whichever rename landed (both callers see the same final key).
      decode_keypair(final)
    end
  end

  defp publish_public_keys(keys) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    path = Path.join(data_dir, @public_keys_file)
    suffix = System.unique_integer([:positive, :monotonic])
    tmp = Path.join(data_dir, ".#{@public_keys_file}.#{suffix}.tmp")
    contents = Jason.encode!(Enum.map(keys, &Base.encode64/1)) <> "\n"

    result =
      with :ok <- File.mkdir_p(data_dir),
           :ok <- File.write(tmp, contents, [:write]),
           :ok <- File.chmod(tmp, 0o644),
           :ok <- File.rename(tmp, path) do
        :ok
      end

    if result != :ok do
      _ = File.rm(tmp)
    end

    result
  end

  defp decode_public_keys(contents) do
    with {:ok, encoded_keys} when is_list(encoded_keys) <- Jason.decode(contents),
         {:ok, keys} <- decode_public_key_list(encoded_keys) do
      {:ok, keys}
    else
      _ -> {:error, :corrupt_node_public_keys}
    end
  end

  defp decode_public_key_list(encoded_keys) do
    Enum.reduce_while(encoded_keys, {:ok, []}, fn encoded, {:ok, keys} ->
      case is_binary(encoded) && Base.decode64(encoded) do
        {:ok, key} when byte_size(key) == 32 -> {:cont, {:ok, [key | keys]}}
        _ -> {:halt, {:error, :corrupt_node_public_keys}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      {:error, _} = err -> err
    end
  end
end
