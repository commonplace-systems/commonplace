defmodule Commonplace.MCP.Tools.BdFrontier do
  @moduledoc """
  MCP tool: a summary of the ticket-DAG frontier — ready/blocked counts
  plus stranded (dependency-hell) components (Bd P2 Tier-1 read tools).

  Runs both queries on the serve via `BdRoute` (bounded rpcs), never N
  nested remote CommitStoreClient calls (CX-z0v7 rationale).
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdRows, Response}
  alias Commonplace.Store.CommitStoreClient

  def descriptor do
    %{
      "name" => "bd_frontier",
      "description" =>
        "Summarize the commonplace ticket-DAG frontier: how many tickets are ready, how many blocked, and any stranded connected components (open tickets that can never become ready — dependency hell). No arguments.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(_args, _context) do
    with {:ok, root} <- BdRows.resolve_root(),
         %{ready: ready, blocked: blocked} <-
           BdRoute.call(Commonplace.Bd.Frontier, :compute, [root, CommitStoreClient]),
         stranded when is_list(stranded) <-
           BdRoute.call(Commonplace.Bd.Frontier, :stranded_components, [root, CommitStoreClient]) do
      ready_count = Enum.count(ready)
      blocked_count = Enum.count(blocked)
      stranded_json = Enum.map(stranded, &normalize_component/1)

      structured = %{
        "ready_count" => ready_count,
        "blocked_count" => blocked_count,
        "stranded" => stranded_json
      }

      {:ok, Response.text(summary(ready_count, blocked_count, stranded_json), structured)}
    else
      {:error, reason} ->
        {:error, :invalid_params, "bd_frontier failed: #{inspect(reason)}"}

      other ->
        {:error, :invalid_params, "bd_frontier failed: #{inspect(other)}"}
    end
  end

  # A stranded component is a list of ticket ids (Frontier.stranded_components).
  defp normalize_component(component) when is_list(component), do: Enum.map(component, &to_string/1)
  defp normalize_component(other), do: other

  defp summary(ready_count, blocked_count, stranded) do
    header = "#{ready_count} ready, #{blocked_count} blocked, #{length(stranded)} stranded component(s)."

    case stranded do
      [] ->
        header

      components ->
        lines =
          components
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {ids, i} -> "  ##{i}: #{Enum.join(ids, ", ")}" end)

        "#{header}\nStranded:\n#{lines}"
    end
  end
end
