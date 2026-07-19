defmodule Commonplace.MCP.Tools.BdUpdate do
  @moduledoc """
  MCP tool (Tier-2 WRITE): update non-protected fields on a ticket.

  Routes the `ticket_update` view action through
  `Commonplace.ViewActionDispatch` on the serve via `BdRoute`, carrying
  a `signing_context` from `BdWrite` (enforce-mode).

  `WriteGuard` refuses the PROTECTED fields (`status`, `done_witness`,
  `claimed_by`) via this path — those move only through
  `bd_close` / `bd_claim` / `bd_release`. A payload touching a protected
  field returns a clean refusal string surfaced here as `invalid_params`.
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdWrite, Response}

  def descriptor do
    %{
      "name" => "bd_update",
      "description" =>
        "Update non-protected fields on a ticket (e.g. title, priority, type, owner, labels, description). The protected fields status/done_witness/claimed_by are refused here — use bd_close, bd_claim, or bd_release. Pass `changes` as a field→value map.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "ticket" => %{"type" => "string", "description" => "Ticket id to update."},
          "changes" => %{
            "type" => "object",
            "description" => "Map of field name → new value."
          }
        },
        "required" => ["ticket", "changes"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(args, context) when is_map(args) and is_map(context) do
    ticket = Map.get(args, "ticket")
    changes = Map.get(args, "changes")

    cond do
      not (is_binary(ticket) and ticket != "") ->
        {:error, :invalid_params, "bd_update requires a non-empty string \"ticket\"."}

      not (is_map(changes) and map_size(changes) > 0) ->
        {:error, :invalid_params, "bd_update requires a non-empty \"changes\" map."}

      true ->
        update(String.trim(ticket), changes, context)
    end
  end

  defp update(ticket, changes, context) do
    case BdWrite.signing_context(context) do
      %Commonplace.Crypto.SigningContext{} = sc ->
        dispatch =
          BdRoute.call(Commonplace.ViewActionDispatch, :dispatch, [
            "ticket_update",
            %{args: %{"ticket" => ticket, "changes" => changes}, signing_context: sc}
          ])

        case dispatch do
          {:ok, :tree_mutation, _details} ->
            {:ok,
             Response.text("Updated #{ticket}.", %{
               "ticket" => ticket,
               "changes" => changes
             })}

          {:error, msg} when is_binary(msg) ->
            {:error, :invalid_params, msg}

          other ->
            {:error, :invalid_params, "bd_update failed: #{inspect(other)}"}
        end

      {:error, :no_signing_context} ->
        {:error, :invalid_params, "bd_update failed: no signing context available."}
    end
  end
end
