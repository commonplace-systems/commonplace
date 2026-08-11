defmodule CommonplaceWebWeb.CertMintController do
  use CommonplaceWebWeb, :controller

  alias Commonplace.CertMint

  def create(conn, params) do
    if loopback?(conn.remote_ip) do
      mint(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "cert-mint refused: endpoint is local-only"})
    end
  end

  defp mint(
         conn,
         %{
           "scope" => scope,
           "verbs" => verb_names,
           "audience" => audience_uuid
         } = params
       )
       when is_binary(scope) and is_list(verb_names) and is_binary(audience_uuid) do
    with {:ok, verbs} <- decode_verbs(verb_names),
         {:ok, expiry} <- decode_expiry(Map.get(params, "expiry")),
         {:ok, cap} <- CertMint.mint(scope, verbs, audience_uuid, expiry) do
      conn
      |> put_status(:created)
      |> json(%{cid: Base.encode16(cap.id, case: :lower)})
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: CertMint.refusal_text(reason)})
    end
  end

  defp mint(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "cert-mint refused: malformed request"})
  end

  defp decode_verbs(names) do
    mapping = %{
      "write" => :write,
      "execute" => :execute,
      "delegate" => :delegate,
      "read" => :read,
      "bless" => :bless,
      "define_verb" => :define_verb
    }

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, verbs} ->
      case Map.fetch(mapping, name) do
        {:ok, verb} -> {:cont, {:ok, [verb | verbs]}}
        :error -> {:halt, {:error, {:unknown_verb, name}}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :verbs_required}
      {:ok, verbs} -> {:ok, verbs |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp decode_expiry(nil), do: {:ok, nil}

  defp decode_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expiry, _offset} -> {:ok, expiry}
      {:error, reason} -> {:error, {:bad_expiry, reason}}
    end
  end

  defp decode_expiry(_value), do: {:error, :bad_expiry}

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_remote_ip), do: false
end
