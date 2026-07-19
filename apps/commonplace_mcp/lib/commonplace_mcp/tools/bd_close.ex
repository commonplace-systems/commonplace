defmodule Commonplace.MCP.Tools.BdClose do
  @moduledoc """
  MCP tool (Tier-2 WRITE): close a ticket (status → "closed").

  Routes the `ticket_close` view action through
  `Commonplace.ViewActionDispatch` on the serve via `BdRoute`, carrying
  a `signing_context` from `BdWrite` (enforce-mode).

  Close is gated on the ticket's OWN `done_when`: a `manual` ticket
  needs no witness, while e.g. `pr_merge` requires witness cids. The
  client proposes candidate proofs via `witnesses` (default `[]`); the
  `CloseGate` resolves them or returns a sanitized refusal, surfaced
  here as `invalid_params`.
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdWrite, Response}

  def descriptor do
    %{
      "name" => "bd_close",
      "description" =>
        "Close a ticket (status → \"closed\"). A manual-done_when ticket needs no witness; gated done_when kinds (e.g. pr_merge) require proof cids passed via `witnesses`. Returns the closed status and recorded done_witness.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "ticket" => %{"type" => "string", "description" => "Ticket id to close."},
          "witnesses" => %{
            "type" => "array",
            "description" =>
              "Optional list of candidate proof cids (hex strings). Required only for gated done_when kinds.",
            "items" => %{"type" => "string"}
          }
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
        close(String.trim(ticket), Map.get(args, "witnesses", []), context)

      _ ->
        {:error, :invalid_params, "bd_close requires a non-empty string \"ticket\"."}
    end
  end

  defp close(ticket, witnesses, context) when is_list(witnesses) do
    case BdWrite.signing_context(context) do
      %Commonplace.Crypto.SigningContext{} = sc ->
        dispatch =
          BdRoute.call(Commonplace.ViewActionDispatch, :dispatch, [
            "ticket_close",
            %{args: %{"ticket" => ticket, "witnesses" => witnesses}, signing_context: sc}
          ])

        case dispatch do
          {:ok, :tree_mutation, details} ->
            {:ok,
             Response.text("Closed #{ticket}.", %{
               "ticket" => ticket,
               "status" => details[:status] || details["status"],
               "done_witness" => details[:done_witness] || details["done_witness"]
             })}

          {:error, msg} when is_binary(msg) ->
            {:error, :invalid_params, msg}

          other ->
            {:error, :invalid_params, "bd_close failed: #{inspect(other)}"}
        end

      {:error, :no_signing_context} ->
        {:error, :invalid_params, "bd_close failed: no signing context available."}
    end
  end

  defp close(_ticket, _witnesses, _context) do
    {:error, :invalid_params, "bd_close \"witnesses\" must be a list."}
  end
end
