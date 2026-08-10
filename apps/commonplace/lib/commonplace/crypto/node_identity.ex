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
  @encoded_public_key_line_bytes 45

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

  @doc """
  Ensure the public-key artifact exists before the application starts its
  supervision tree.

  Existing artifacts are validated through `public_keys/0` and republished
  atomically. For an identity created before the public artifact was
  introduced, this reads and decodes only the key file's first (public-key)
  line, then publishes it atomically. It never reads the private-key line and
  never mints an identity.
  """
  @spec publish_public_keys_at_boot() :: :ok | {:error, term()}
  def publish_public_keys_at_boot do
    case public_keys() do
      {:ok, keys} -> publish_public_keys(keys)
      :absent -> publish_existing_public_key()
      {:error, _} = err -> err
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

  defp publish_existing_public_key do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    path = Path.join(data_dir, @key_file)

    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, device} ->
        result =
          case :file.read(device, @encoded_public_key_line_bytes) do
            {:ok, <<encoded_public_key::binary-size(44), "\n">>} ->
              with {:ok, public_key} <- Base.decode64(encoded_public_key),
                   true <- byte_size(public_key) == 32 do
                publish_public_keys([public_key])
              else
                _ -> {:error, :corrupt_node_key}
              end

            {:ok, _} ->
              {:error, :corrupt_node_key}

            :eof ->
              {:error, :corrupt_node_key}

            {:error, _} = err ->
              err
          end

        :ok = :file.close(device)
        result

      {:error, :enoent} ->
        :ok

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
    tmp = Path.join(data_dir, ".#{@key_file}.#{mint_temp_suffix()}.tmp")

    result =
      with :ok <- File.mkdir_p(data_dir),
           :ok <- File.write(tmp, contents, [:write]),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- link_into_place(tmp, path),
           :ok <- drop_temp(tmp),
           {:ok, final} <- File.read(path) do
        # Re-read after linking so concurrent first-boot races settle on
        # whichever mint landed first (both callers see the same final key).
        decode_keypair(final)
      end

    # Covers the paths that failed before `drop_temp/1` ran. The temp file is
    # ours alone, so removing it never touches another caller's mint.
    _ = File.rm(tmp)
    result
  end

  # Unlink our temp name as soon as `path` is published — on the winning path it
  # is a second link to the very inode now at `path`, so the key is already safe
  # and dropping it early keeps the temp's lifetime as short as the old rename's.
  # This is not just tidiness: holding the temp until after the read-back left an
  # extra entry in data_dir for the whole decode, which measurably widened the
  # window for a concurrent directory walk to trip over an entry that appeared
  # mid-walk (it reddened a trust-suite teardown at seed 422078). Never fails the
  # mint — `path` is already published, so a failed cleanup is not a mint error.
  defp drop_temp(tmp) do
    _ = File.rm(tmp)
    :ok
  end

  # A per-caller temp name (CX-37d9): a FIXED one let two concurrent first-use
  # mints share a single temp file, so one caller's rename consumed the other's
  # — the same defect that raced on the public-key path on 2026-08-09.
  #
  # `System.unique_integer/1` ALONE is not enough here, and this is the part a
  # later reader is most likely to "simplify" back: it is unique per BEAM VM,
  # not per machine. Two nodes cold-starting against a SHARED data_dir — the
  # multi-node case this ticket was filed for — can each draw the same integer
  # and land on the same temp path. That one does not diverge (both callers
  # read `path` back after linking), but one caller's `File.rm(tmp)` can delete
  # the file the other is about to link, turning its link into :enoent and
  # failing an otherwise fine mint. So the name also carries the OS pid and
  # random bytes, making it unique across processes and machines, not just
  # across schedulers. All three parts are filename-legal (url_encode64 emits
  # only [A-Za-z0-9-_], and we drop the padding).
  defp mint_temp_suffix do
    rand = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{System.pid()}.#{System.unique_integer([:positive, :monotonic])}.#{rand}"
  end

  # This fix does NOT close the cold-start identity race. `Workspace`'s
  # `write_fresh_node_id/2` (workspace.ex:125) still has exactly this defect —
  # fixed temp name plus a clobbering rename — and races in the very same
  # first-boot window. It is tracked as CX-kmtq and is not fixed here.
  #
  # The asymmetry is the part worth carrying: the race fixed below was the LOUD
  # one, failing an :enoent straight out of `signing_context/0`. The node_id race
  # is SILENT — two callers simply walk away with different node_ids. And node_id
  # is the identity this signing key is BOUND TO, so the quieter bug is attached
  # to the more load-bearing value.
  #
  # `File.rename/2` cannot express "create, but never clobber": the loser of a
  # mint race would overwrite the winner's key and the two callers would walk
  # away holding DIFFERENT private keys for one node_id (measured, CX-37d9).
  # A hard link fails with :eexist instead, which is success for us — the key
  # already exists, and the caller reads it back below. The link also carries
  # the inode's 0o600 mode, so the published key is never briefly world-readable.
  defp link_into_place(tmp, path) do
    case File.ln(tmp, path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} = err -> err
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
