defmodule Commonplace.Runner.PodIdentity do
  @moduledoc """
  The short-lived signing identity placed in one reapable runner pod home.

  This is deliberately separate from `Commonplace.Crypto.NodeIdentity`: the
  durable node key remains at its standing masked path, while this key exists
  only for the lifetime of the pod home. The runner needs the same ephemeral
  private key after namespace exit so a verified WAL intent can be persisted
  under the pod signer before the home is removed.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}

  @key_file "pod_signing_key"

  @doc "Mint one new pod identity before launch and publish it atomically."
  @spec mint(Path.t()) :: {:ok, SigningContext.t()} | {:error, term()}
  def mint(data_dir) when is_binary(data_dir) do
    path = key_path(data_dir)
    {public_key, private_key} = Signing.generate_keypair()

    context = %SigningContext{
      identity_uuid: UUID.uuid4(),
      public_key: public_key,
      private_key: private_key
    }

    contents =
      Jason.encode!(%{
        "identity" => context.identity_uuid,
        "private-key" => Base.encode64(private_key),
        "public-key" => Base.encode64(public_key)
      }) <> "\n"

    tmp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    result =
      with :ok <- File.mkdir_p(data_dir),
           :ok <- File.write(tmp, contents, [:write]),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.ln(tmp, path),
           {:ok, reread} <- signing_context(data_dir),
           true <- same_context?(context, reread) or {:error, :pod_signing_key_reread_mismatch} do
        {:ok, reread}
      end

    _ = File.rm(tmp)
    result
  end

  @doc "Read the pod-held ephemeral signing context from its explicit path."
  @spec signing_context(Path.t()) :: {:ok, SigningContext.t()} | {:error, term()}
  def signing_context(data_dir) when is_binary(data_dir) do
    with {:ok, contents} <- File.read(key_path(data_dir)),
         {:ok, document} when is_map(document) <- Jason.decode(contents),
         identity when is_binary(identity) and identity != "" <- document["identity"],
         {:ok, public_key} <- decode_key(document["public-key"], 32),
         {:ok, private_key} <- decode_key(document["private-key"], 32) do
      {:ok,
       %SigningContext{
         identity_uuid: identity,
         public_key: public_key,
         private_key: private_key
       }}
    else
      {:error, :enoent} -> {:error, :pod_signing_key_absent}
      {:error, _reason} = error -> error
      _other -> {:error, :corrupt_pod_signing_key}
    end
  end

  @doc "Return the key pathname used by both the pod and runner."
  @spec key_path(Path.t()) :: Path.t()
  def key_path(data_dir) when is_binary(data_dir), do: Path.join(data_dir, @key_file)

  defp decode_key(encoded, bytes) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == bytes -> {:ok, key}
      _other -> {:error, :corrupt_pod_signing_key}
    end
  end

  defp decode_key(_encoded, _bytes), do: {:error, :corrupt_pod_signing_key}

  defp same_context?(left, right) do
    left.identity_uuid == right.identity_uuid and left.public_key == right.public_key and
      left.private_key == right.private_key
  end
end
