defmodule Commonplace.MCP.Tools.BdRelease do
  @moduledoc """
  MCP tool (Tier-2 WRITE): release a ticket — free its green possession
  token and clear `claimed_by`.

  Routes the `ticket_release` view action through
  `Commonplace.ViewActionDispatch` on the serve via `BdRoute`, carrying
  a `signing_context` from `BdWrite` (enforce-mode). Only the current
  holder may release; a non-holder release returns a clean refusal
  string surfaced here as `invalid_params`.

  See `BdWrite` for the v1 node-signing caveat that makes all MCP
  callers share one principal today.
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdWrite, Response}

  def descriptor do
    %{
      "name" => "bd_release",
      "description" =>
        "Release a ticket you hold — frees its possession token and clears claimed_by. Only the current holder may release.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "ticket" => %{"type" => "string", "description" => "Ticket id to release."}
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
        release(String.trim(ticket), context)

      _ ->
        {:error, :invalid_params, "bd_release requires a non-empty string \"ticket\"."}
    end
  end

  defp release(ticket, context) do
    case BdWrite.signing_context(context) do
      %Commonplace.Crypto.SigningContext{} = sc ->
        dispatch =
          BdRoute.call(Commonplace.ViewActionDispatch, :dispatch, [
            "ticket_release",
            %{args: %{"ticket" => ticket}, signing_context: sc}
          ])

        case dispatch do
          {:ok, :tree_mutation, _details} ->
            {:ok, Response.text("Released #{ticket}.", %{"ticket" => ticket})}

          {:error, msg} when is_binary(msg) ->
            {:error, :invalid_params, msg}

          other ->
            {:error, :invalid_params, "bd_release failed: #{inspect(other)}"}
        end

      {:error, :no_signing_context} ->
        {:error, :invalid_params, "bd_release failed: no signing context available."}
    end
  end
end
