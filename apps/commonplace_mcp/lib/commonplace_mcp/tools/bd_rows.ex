defmodule Commonplace.MCP.Tools.BdRows do
  @moduledoc """
  Shared formatting/root-resolution helpers for the bd Tier-1 read
  tools (`bd_ready`, `bd_blocked`, `bd_frontier`, `bd_show`).

  Not an MCP tool itself — a plain helper (like `BdRoute`), so it is
  NOT registered in `Commonplace.MCP.Tools`.

  `Bd.CLI.ready/2` and `Bd.CLI.blocked/2` return display rows — plain
  maps with ATOM keys `%{id:, priority:, type:, title:, status:,
  claimed_by:}`. These helpers turn a row into the string-keyed JSON
  shape MCP structured output expects, and into one compact text line.
  """

  alias Commonplace.MCP.Tools.BdRoute

  @doc """
  Resolve the workspace root by ROUTING `Workspace.root_uuid/0`
  through `BdRoute` — the escript has no local workspace, so the root
  must be read on the serve, not locally.
  """
  @spec resolve_root() :: {:ok, String.t()} | {:error, term()}
  def resolve_root do
    case BdRoute.call(Commonplace.Workspace, :root_uuid, []) do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_root, other}}
    end
  end

  @doc "Convert a `Bd.CLI` display row (atom keys) to a string-keyed JSON map."
  def row_to_json(%{} = row) do
    %{
      "id" => Map.get(row, :id),
      "priority" => Map.get(row, :priority),
      "type" => Map.get(row, :type),
      "title" => Map.get(row, :title),
      "status" => Map.get(row, :status),
      "claimed_by" => Map.get(row, :claimed_by)
    }
  end

  @doc """
  One compact display line for a JSON row:

      CX-abc  [p1/bug]  fix the thing  (open, claimed_by: alice)
  """
  def row_line(%{} = row) do
    id = row["id"] || "?"
    priority = row["priority"] || "?"
    type = row["type"] || "?"
    title = row["title"] || ""
    status = row["status"] || "?"

    base = "#{id}  [#{priority}/#{type}]  #{title}"

    case row["claimed_by"] do
      nil -> "#{base}  (#{status})"
      "" -> "#{base}  (#{status})"
      claimed_by -> "#{base}  (#{status}, claimed_by: #{claimed_by})"
    end
  end

  @doc "Text summary: a header count plus one line per row."
  def rows_summary(label, []), do: "No #{label} tickets."

  def rows_summary(label, rows) when is_list(rows) do
    lines = Enum.map_join(rows, "\n", &row_line/1)
    "#{length(rows)} #{label} ticket(s):\n#{lines}"
  end
end
