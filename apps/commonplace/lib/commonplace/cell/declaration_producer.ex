defmodule Commonplace.Cell.DeclarationProducer do
  @moduledoc """
  Writes a spawned cell's public identity declaration to a caller-owned path.

  The producer receives no key store, signing context, capability, receipt
  address, or commit-store handle. It obtains only named public receipt fields
  through `Commonplace.Identity.SpawnCeremony.read_public_receipt/2`, writes the
  declaration, and verifies it by re-reading the file.
  """

  alias Commonplace.Cell.Declaration
  alias Commonplace.Identity.SpawnCeremony

  @doc "Write and re-read one spawned cell declaration."
  @spec write(GenServer.server(), String.t(), Path.t()) ::
          {:ok, Declaration.t()} | {:error, term()}
  def write(ceremony, name, path) when is_binary(name) and is_binary(path) do
    with {:ok, receipt} <- SpawnCeremony.read_public_receipt(ceremony, name),
         declaration = %{
           "child_uuid" => receipt["child_uuid"],
           "name" => receipt["name"],
           "public_key" => receipt["public_key"]
         },
         {:ok, encoded} <- Declaration.encode(declaration),
         :ok <- write_file(path, encoded),
         {:ok, reread_document} <- read_file(path),
         {:ok, verified} <- Declaration.decode(reread_document),
         {:ok, expected} <- Declaration.decode(encoded),
         true <- verified == expected or {:error, :declaration_reread_mismatch} do
      {:ok, verified}
    end
  end

  defp write_file(path, encoded) do
    case File.write(path, encoded) do
      :ok -> :ok
      {:error, reason} -> {:error, {:declaration_write_failed, path, reason}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, document} -> {:ok, document}
      {:error, reason} -> {:error, {:declaration_read_failed, path, reason}}
    end
  end
end
