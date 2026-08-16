defmodule Commonplace.Cell.DeclarationReconciler do
  @moduledoc """
  Reads one cell declaration and reports whether it diverges from a spawn receipt.

  Agreement compares only `child_uuid`, `name`, and `public_key`, because those
  are the declaration's bounded projection of the public receipt;
  receipt-only `request_digest` and `status` fields do not participate.
  Conclusive comparisons return `{:ok, divergences}`. Failures to produce a
  comparison return `{:inconclusive, reasons}`, with each reason named. A cell
  that was never spawned (no declaration, no receipt) is reported distinctly
  as `{:ok, :nothing_to_compare}`, so that state is never confused with either
  an inconclusive comparison or a spawned cell whose documents agree
  (`{:ok, []}`).

  The reconciler holds no key material and repairs nothing. Receipt access goes
  exclusively through `Commonplace.Identity.SpawnCeremony.read_public_receipt/2`.
  """

  alias Commonplace.Cell.Declaration
  alias Commonplace.Identity.SpawnCeremony

  @divergence_kinds [
    :declaration_missing,
    :receipt_missing,
    :public_key_mismatch
  ]

  @non_divergence_kinds [
    :child_uuid_mismatch,
    :name_mismatch,
    :declaration_invalid
  ]

  @dispositions %{
    receipt_missing: :wait,
    declaration_missing: :update_from_receipt,
    public_key_mismatch: {:refuse, :public_key_mismatch}
  }

  @disposition_names [:wait, :update_from_receipt, :refuse]

  @type value_divergence :: %{
          required(:kind) => :public_key_mismatch,
          required(:declaration) => term(),
          required(:receipt) => term()
        }

  @type divergence ::
          %{required(:kind) => :declaration_missing | :receipt_missing}
          | value_divergence()

  @type value_non_divergence :: %{
          required(:kind) => :child_uuid_mismatch | :name_mismatch,
          required(:declaration) => term(),
          required(:receipt) => term()
        }

  @type non_divergence ::
          %{required(:kind) => :declaration_invalid, required(:reason) => term()}
          | value_non_divergence()

  @type disposition :: :wait | :update_from_receipt | {:refuse, atom()}

  @doc "Return the closed set of divergence names this reconciler can report."
  @spec divergence_kinds() :: [atom()]
  def divergence_kinds, do: @divergence_kinds

  @doc "Return the closed set of names for inconclusive comparison results."
  @spec non_divergence_kinds() :: [atom()]
  def non_divergence_kinds, do: @non_divergence_kinds

  @doc "Return the closed set of disposition names."
  @spec disposition_names() :: [atom()]
  def disposition_names, do: @disposition_names

  @doc "Classify a real divergence without performing the disposition."
  @spec disposition(%{required(:kind) => atom()}) :: disposition()
  def disposition(%{kind: kind}) when is_atom(kind) do
    @dispositions
    |> Map.fetch(kind)
    |> disposition_result(kind)
  end

  @doc "Read and compare one declaration/receipt pair without changing either side."
  @spec reconcile(GenServer.server(), String.t(), Path.t()) ::
          {:ok, [divergence()] | :nothing_to_compare}
          | {:inconclusive, [non_divergence()]}
          | {:error, term()}
  def reconcile(ceremony, name, declaration_path)
      when is_binary(name) and is_binary(declaration_path) do
    with {:ok, declaration} <- read_declaration(declaration_path),
         {:ok, receipt} <- read_receipt(ceremony, name) do
      compare(declaration, receipt)
    end
  end

  defp disposition_result({:ok, disposition}, _kind), do: disposition
  defp disposition_result(:error, kind), do: {:refuse, kind}

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

  defp compare(:missing, :missing), do: {:ok, :nothing_to_compare}

  defp compare(:missing, {:present, _receipt}),
    do: {:ok, [%{kind: :declaration_missing}]}

  defp compare({:present, _declaration}, :missing),
    do: {:ok, [%{kind: :receipt_missing}]}

  defp compare({:invalid, reason}, :missing),
    do: {:inconclusive, [%{kind: :declaration_invalid, reason: reason}]}

  defp compare({:invalid, reason}, {:present, _receipt}),
    do: {:inconclusive, [%{kind: :declaration_invalid, reason: reason}]}

  defp compare({:present, declaration}, {:present, receipt}) do
    non_divergences =
      []
      |> compare_child_uuid(declaration, receipt)
      |> compare_name(declaration, receipt)
      |> Enum.reverse()

    case non_divergences do
      [] -> {:ok, compare_public_key([], declaration, receipt)}
      reasons -> {:inconclusive, reasons}
    end
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
