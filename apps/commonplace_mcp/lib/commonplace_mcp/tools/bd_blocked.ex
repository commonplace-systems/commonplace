defmodule Commonplace.MCP.Tools.BdBlocked do
  @moduledoc """
  MCP tool: the ticket-DAG's BLOCKED set — open tickets with at least
  one unsatisfied `needs` entry — priority-sorted (Bd P2 Tier-1 read
  tools).

  Runs the whole query on the serve via `BdRoute` (one bounded rpc),
  never N nested remote CommitStoreClient calls (CX-z0v7 rationale).
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdRows, Response}
  alias Commonplace.Store.CommitStoreClient

  def descriptor do
    %{
      "name" => "bd_blocked",
      "description" =>
        "List BLOCKED tickets from the commonplace ticket-DAG (open tickets with at least one unsatisfied `needs` entry), priority-sorted. No arguments. Returns each ticket's id, priority, type, title, status, and claimed_by.",
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
         rows when is_list(rows) <-
           BdRoute.call(Commonplace.Bd.CLI, :blocked, [root, CommitStoreClient]) do
      json_rows = Enum.map(rows, &BdRows.row_to_json/1)
      {:ok, Response.text(BdRows.rows_summary("blocked", json_rows), %{"blocked" => json_rows})}
    else
      {:error, reason} ->
        {:error, :invalid_params, "bd_blocked failed: #{inspect(reason)}"}
    end
  end
end
