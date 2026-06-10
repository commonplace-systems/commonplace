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

  @key_file "node_signing_key"

  @doc """
  Return the node's `%SigningContext{}`, minting the keypair on first
  use. `{:error, reason}` only on filesystem errors that prevent both
  reading and creating the key (callers treat that as "no node signer
  available" and fall back to leaving the commit unsigned).
  """
  @spec signing_context() :: {:ok, SigningContext.t()} | {:error, term()}
  def signing_context do
    with {:ok, identity} <- Commonplace.Workspace.node_id(),
         {:ok, {pub, priv}} <- load_or_mint_keypair() do
      {:ok,
       %SigningContext{
         identity_uuid: identity,
         private_key: priv,
         public_key: pub
       }}
    end
  end

  @doc "The node identity's raw Ed25519 public key."
  @spec public_key() :: {:ok, binary()} | {:error, term()}
  def public_key do
    with {:ok, {pub, _priv}} <- load_or_mint_keypair(), do: {:ok, pub}
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
        mint_keypair(data_dir, path)

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
end
