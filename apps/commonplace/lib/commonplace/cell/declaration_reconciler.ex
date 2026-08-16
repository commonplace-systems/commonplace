defmodule Commonplace.Cell.DeclarationReconciler do
  @moduledoc """
  Reads one cell declaration and reports how it diverges from a spawn receipt.

  Agreement compares only `child_uuid`, `name`, and `public_key`, because those
  are the declaration's bounded projection of the public receipt;
  receipt-only `request_digest` and `status` fields do not participate. A cell
  that was never spawned (no declaration, no receipt) is reported distinctly
  as `{:ok, :nothing_to_compare}`, so that state is never confused with a
  spawned cell whose declaration and receipt agree (`{:ok, []}`).

  The reconciler holds no key material and repairs nothing. Receipt access goes
  exclusively through `Commonplace.Identity.SpawnCeremony.read_public_receipt/2`.
  """

  alias Commonplace.Cell.Declaration
  alias Commonplace.Identity.SpawnCeremony

  @divergence_kinds [
    :declaration_missing,
    :receipt_missing,
    :declaration_invalid,
    :child_uuid_mismatch,
    :name_mismatch,
    :public_key_mismatch
  ]

  @type value_mismatch :: %{
          required(:kind) => :child_uuid_mismatch | :name_mismatch | :public_key_mismatch,
          required(:declaration) => term(),
          required(:receipt) => term()
        }

  @type divergence ::
          %{required(:kind) => :declaration_missing | :receipt_missing}
          | %{required(:kind) => :declaration_invalid, required(:reason) => term()}
          | value_mismatch()

  @doc "Return the closed set of divergence names this reconciler can report."
  @spec divergence_kinds() :: [atom()]
  def divergence_kinds, do: @divergence_kinds

  @doc "Read and compare one declaration/receipt pair without changing either side."
  @spec reconcile(GenServer.server(), String.t(), Path.t()) ::
          {:ok, [divergence()] | :nothing_to_compare} | {:error, term()}
  def reconcile(ceremony, name, declaration_path)
      when is_binary(name) and is_binary(declaration_path) do
    with {:ok, declaration} <- read_declaration(declaration_path),
         {:ok, receipt} <- read_receipt(ceremony, name) do
      {:ok, compare(declaration, receipt)}
    end
  end

  defp read_declaration(path) do
    case File.read(path) do
      {:ok, document} ->
        case Declaration.decode(document) do
          {:ok, declaration} -> {:ok, {:present, declaration}}
          {:error, reason} -> {:ok, {:invalid, reason}}
        end

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, {:declaration_read_failed, path, reason}}
    end
  end

  defp read_receipt(ceremony, name) do
    case SpawnCeremony.read_public_receipt(ceremony, name) do
      {:ok, receipt} -> {:ok, {:present, receipt}}
      {:error, :receipt_not_found} -> {:ok, :missing}
      {:error, reason} -> {:error, {:receipt_read_failed, name, reason}}
    end
  end

  defp compare(:missing, :missing), do: :nothing_to_compare

  defp compare(:missing, {:present, _receipt}),
    do: [%{kind: :declaration_missing}]

  defp compare({:present, _declaration}, :missing),
    do: [%{kind: :receipt_missing}]

  defp compare({:invalid, reason}, :missing),
    do: [%{kind: :declaration_invalid, reason: reason}, %{kind: :receipt_missing}]

  defp compare({:invalid, reason}, {:present, _receipt}),
    do: [%{kind: :declaration_invalid, reason: reason}]

  defp compare({:present, declaration}, {:present, receipt}) do
    []
    |> compare_child_uuid(declaration, receipt)
    |> compare_name(declaration, receipt)
    |> compare_public_key(declaration, receipt)
    |> Enum.reverse()
  end

  defp compare_child_uuid(divergences, declaration, receipt) do
    compare_value(
      divergences,
      :child_uuid_mismatch,
      declaration.child_uuid,
      receipt["child_uuid"]
    )
  end

  defp compare_name(divergences, declaration, receipt) do
    compare_value(divergences, :name_mismatch, declaration.name, receipt["name"])
  end

  defp compare_public_key(divergences, declaration, receipt) do
    compare_value(
      divergences,
      :public_key_mismatch,
      declaration.public_key,
      receipt["public_key"]
    )
  end

  defp compare_value(divergences, _kind, value, value), do: divergences

  defp compare_value(divergences, kind, declaration_value, receipt_value) do
    [
      %{kind: kind, declaration: declaration_value, receipt: receipt_value}
      | divergences
    ]
  end
end
