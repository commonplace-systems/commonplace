defmodule Commonplace.MCP.Tools.BdClaim do
  @moduledoc """
  MCP tool (Tier-2 WRITE): claim a ticket — take its exclusive green
  possession token.

  Routes the `ticket_claim` view action through
  `Commonplace.ViewActionDispatch` on the serve via `BdRoute`, carrying
  a `signing_context` from `BdWrite` (enforce-mode). The claimer is
  resolved SERVER-SIDE from the signing_context; claiming does not move
  the ticket, it just pins the custody token and mirrors `claimed_by`.

  A contested claim (token already held by someone else) returns a
  sanitized "already claimed" string surfaced here as `invalid_params`.

  ## v1 claim caveat

  Under v1 node-signing (see `BdWrite`), every MCP caller shares the
  NODE principal, so claim exclusivity between different MCP agents is
  not yet meaningful — real multi-agent claim exclusivity needs the
  per-agent keys from CX-hk0s.
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdWrite, Response}

  def descriptor do
    %{
      "name" => "bd_claim",
      "description" =>
        "Claim a ticket by taking its exclusive possession token. The claimer is derived from the signing key server-side. A ticket already claimed by another principal is refused. Release with bd_release.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "ticket" => %{"type" => "string", "description" => "Ticket id to claim."}
        },
        "required" => ["ticket"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(args, context) when is_map(args) and is_map(context) do
    case Map.get(args, "ticket") do
      ticket when is_binary(ticket) and ticket != "" ->
        claim(String.trim(ticket), context)

      _ ->
        {:error, :invalid_params, "bd_claim requires a non-empty string \"ticket\"."}
    end
  end

  defp claim(ticket, context) do
    case BdWrite.signing_context(context) do
      %Commonplace.Crypto.SigningContext{} = sc ->
        dispatch =
          BdRoute.call(Commonplace.ViewActionDispatch, :dispatch, [
            "ticket_claim",
            %{args: %{"ticket" => ticket}, signing_context: sc}
          ])

        case dispatch do
          {:ok, :tree_mutation, details} ->
            {:ok,
             Response.text("Claimed #{ticket}.", %{
               "ticket" => ticket,
               "claimed_by" => details[:claimed_by] || details["claimed_by"]
             })}

          {:error, msg} when is_binary(msg) ->
            {:error, :invalid_params, msg}

          other ->
            {:error, :invalid_params, "bd_claim failed: #{inspect(other)}"}
        end

      {:error, :no_signing_context} ->
        {:error, :invalid_params, "bd_claim failed: no signing context available."}
    end
  end
end
