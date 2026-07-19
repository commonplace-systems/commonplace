defmodule Commonplace.MCP.Tools.BdAddNeeds do
  @moduledoc """
  MCP tool (Tier-2 WRITE): add a dependency edge to the ticket-DAG —
  `ticket` needs `needs_ticket`.

  Routes the `ticket_add_needs` view action through
  `Commonplace.ViewActionDispatch` on the serve via `BdRoute`, carrying
  a `signing_context` from `BdWrite` (enforce-mode). The dispatch path
  runs the cycle-gate (`WriteGuard`): an edge that would close a cycle
  is refused with a clean error string, surfaced here as `invalid_params`.
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdWrite, Response}

  def descriptor do
    %{
      "name" => "bd_add_needs",
      "description" =>
        "Add a dependency edge to the ticket-DAG: `ticket` will require `needs_ticket` (an optional `needs_repo` names a cross-repo prereq). Cycle-forming edges are refused. Returns the dependent's updated needs list.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "ticket" => %{
            "type" => "string",
            "description" => "The dependent ticket id (the one that gains a prerequisite)."
          },
          "needs_ticket" => %{
            "type" => "string",
            "description" => "The prerequisite ticket id."
          },
          "needs_repo" => %{
            "type" => "string",
            "description" => "Optional repo for a cross-repo prerequisite."
          }
        },
        "required" => ["ticket", "needs_ticket"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(args, context) when is_map(args) and is_map(context) do
    with {:ok, ticket} <- require_arg(args, "ticket"),
         {:ok, needs_ticket} <- require_arg(args, "needs_ticket"),
         sc when is_struct(sc, Commonplace.Crypto.SigningContext) <-
           BdWrite.signing_context(context) do
      args_map =
        %{"ticket" => ticket, "needs_ticket" => needs_ticket}
        |> maybe_put("needs_repo", Map.get(args, "needs_repo"))

      dispatch =
        BdRoute.call(Commonplace.ViewActionDispatch, :dispatch, [
          "ticket_add_needs",
          %{args: args_map, signing_context: sc}
        ])

      case dispatch do
        {:ok, :tree_mutation, details} ->
          fields = %{"ticket" => ticket, "needs" => details[:needs] || details["needs"]}

          {:ok,
           Response.text("Added edge: #{ticket} needs #{needs_ticket}.", fields)}

        {:error, msg} when is_binary(msg) ->
          {:error, :invalid_params, msg}

        other ->
          {:error, :invalid_params, "bd_add_needs failed: #{inspect(other)}"}
      end
    else
      {:error, :missing, name} ->
        {:error, :invalid_params, "bd_add_needs requires a non-empty string \"#{name}\"."}

      {:error, :no_signing_context} ->
        {:error, :invalid_params, "bd_add_needs failed: no signing context available."}
    end
  end

  defp require_arg(args, name) do
    case Map.get(args, name) do
      v when is_binary(v) and v != "" -> {:ok, String.trim(v)}
      _ -> {:error, :missing, name}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
