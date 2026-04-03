defmodule Commonplace.CLI.Keygen do
  @moduledoc """
  Generate Ed25519 signing keypairs for commit signing.

  The private key is stored in SecretStore (local, never synced).
  The public key is printed and can be registered in the workspace's
  __keys document for signature verification.
  """

  alias Commonplace.Crypto.Signing
  alias Commonplace.Store.SecretStore

  def run(data_dir, _relative_path, args) do
    Commonplace.CLI.ensure_started(data_dir)

    case args do
      [] ->
        generate("default")

      [name] ->
        generate(name)

      _ ->
        IO.puts(:stderr, "Usage: commonplace keygen [name]")
        IO.puts(:stderr, "  name: key identifier (default: 'default')")
        System.halt(1)
    end
  end

  defp generate(name) do
    secret_name = "signing_key:#{name}"

    # Check if key already exists
    case SecretStore.get(secret_name) do
      {:ok, _} ->
        IO.puts(:stderr, "Signing key '#{name}' already exists.")
        IO.puts(:stderr, "Delete it first: commonplace secret delete #{secret_name}")
        System.halt(1)

      :not_found ->
        {pub, priv} = Signing.generate_keypair()

        # Store private key in SecretStore
        SecretStore.set(secret_name, Base.encode64(priv))

        # Also store public key for convenience
        SecretStore.set("signing_pub:#{name}", Base.encode64(pub))

        IO.puts("Generated Ed25519 signing keypair: #{name}")
        IO.puts("Public key: #{Base.encode64(pub)}")
        IO.puts("Fingerprint: #{Signing.fingerprint(pub)}")
        IO.puts("Private key stored in SecretStore as: #{secret_name}")
        IO.puts("")
        IO.puts("To associate with your identity:")
        IO.puts("  commonplace secret set signing_identity=<your-identity-uuid>")
    end
  end
end
