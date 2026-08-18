defmodule Commonplace.Crypto.DelegationRoot do
  @moduledoc """
  The workspace's explicitly provisioned Ed25519 delegation root.

  A delegation root is created only by `provision!/1`. Read functions never
  create key material: absence is a named refusal so an operator cannot
  accidentally replace an established trust root merely by exercising a
  lookup path.

  The private and public halves are separate artifacts under `data_dir`.
  Deployments may mask `delegation_root_key` from ordinary processes while
  leaving `delegation_root_pub` readable for verification. The public read
  therefore has no dependency on the private artifact.

  Although the root shares `data_dir`'s location, its backup story must remain
  distinct from the workspace's backup story. Losing the workspace must not be
  the same event as losing every certificate anchor; operators must preserve
  root recovery material independently and according to their custody policy.
  """

  alias Commonplace.Crypto.Signing

  @key_file "delegation_root_key"
  @public_key_file "delegation_root_pub"
  @ed25519_key_bytes 32

  @doc """
  Explicitly provision a new delegation-root pair.

  The ceremony refuses by name when either artifact already exists and never
  overwrites an existing anchor.
  """
  @spec provision!(Path.t()) :: :ok | {:error, term()}
  def provision!(data_dir) when is_binary(data_dir) do
    private_path = private_path(data_dir)
    public_path = public_path(data_dir)

    case first_existing_path([private_path, public_path]) do
      nil -> create_pair(data_dir, private_path, public_path)
      path -> already_exists(path)
    end
  end

  @doc "Read the public key exclusively from the independently readable public artifact."
  @spec public_key(Path.t()) :: {:ok, binary()} | {:error, term()}
  def public_key(data_dir) when is_binary(data_dir) do
    path = public_path(data_dir)

    case File.read(path) do
      {:ok, encoded} -> decode_public_key(encoded, path)
      {:error, :enoent} -> {:error, {:delegation_root_public_key_absent, path}}
      {:error, reason} -> {:error, {:delegation_root_public_key_unreadable, path, reason}}
    end
  end

  @doc """
  Read the raw private key without ever provisioning a replacement.

  Its explicit absence refusal preserves the CX-8wh1 mint-on-`enoent` lesson:
  lookup is not a key-generation ceremony.
  """
  @spec private_key(Path.t()) :: {:ok, binary()} | {:error, term()}
  def private_key(data_dir) when is_binary(data_dir) do
    path = private_path(data_dir)

    case File.read(path) do
      {:ok, key} when byte_size(key) == @ed25519_key_bytes -> {:ok, key}
      {:ok, _contents} -> {:error, {:corrupt_delegation_root_private_key, path}}
      {:error, :enoent} -> {:error, {:delegation_root_absent, path}}
      {:error, reason} -> {:error, {:delegation_root_private_key_unreadable, path, reason}}
    end
  end

  @doc "Return true only when both delegation-root artifacts exist."
  @spec provisioned?(Path.t()) :: boolean()
  def provisioned?(data_dir) when is_binary(data_dir) do
    File.exists?(private_path(data_dir)) and File.exists?(public_path(data_dir))
  end

  defp create_pair(data_dir, private_path, public_path) do
    {public_key, private_key} = Signing.generate_keypair()
    suffix = temp_suffix()
    private_tmp = Path.join(data_dir, ".#{@key_file}.#{suffix}.tmp")
    public_tmp = Path.join(data_dir, ".#{@public_key_file}.#{suffix}.tmp")

    result =
      with :ok <- File.mkdir_p(data_dir),
           :ok <- write_staged(private_tmp, private_key, 0o600),
           :ok <- write_staged(public_tmp, Signing.encode_key(public_key), 0o644) do
        publish_pair(private_tmp, private_path, public_tmp, public_path)
      end

    _ = File.rm(private_tmp)
    _ = File.rm(public_tmp)
    result
  end

  defp publish_pair(private_tmp, private_path, public_tmp, public_path) do
    case File.ln(private_tmp, private_path) do
      :ok -> publish_public(public_tmp, public_path, private_path)
      {:error, :eexist} -> already_exists(private_path)
      {:error, reason} -> {:error, {:delegation_root_provision_failed, private_path, reason}}
    end
  end

  defp publish_public(public_tmp, public_path, private_path) do
    case File.ln(public_tmp, public_path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        _ = File.rm(private_path)
        already_exists(public_path)

      {:error, reason} ->
        _ = File.rm(private_path)
        {:error, {:delegation_root_provision_failed, public_path, reason}}
    end
  end

  defp write_staged(path, contents, mode) do
    with :ok <- File.write(path, contents, [:write, :exclusive]),
         :ok <- File.chmod(path, mode) do
      :ok
    end
  end

  defp decode_public_key(encoded, path) do
    case Signing.decode_key(encoded) do
      {:ok, key} when byte_size(key) == @ed25519_key_bytes -> {:ok, key}
      _ -> {:error, {:corrupt_delegation_root_public_key, path}}
    end
  end

  defp first_existing_path(paths), do: Enum.find(paths, &File.exists?/1)
  defp already_exists(path), do: {:error, {:delegation_root_already_exists, path}}

  defp private_path(data_dir), do: Path.join(data_dir, @key_file)
  defp public_path(data_dir), do: Path.join(data_dir, @public_key_file)

  defp temp_suffix do
    random = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{System.pid()}.#{System.unique_integer([:positive, :monotonic])}.#{random}"
  end
end
