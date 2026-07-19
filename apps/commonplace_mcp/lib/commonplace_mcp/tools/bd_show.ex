defmodule Commonplace.MCP.Tools.BdShow do
  @moduledoc """
  MCP tool: full detail for one ticket by id — its fields plus its
  description body (Bd P2 Tier-1 read tools).

  Routes both `Bd.Issue.show/3` and `Bd.Issue.description/3` on the
  serve via `BdRoute` (bounded rpcs), never N nested remote
  CommitStoreClient calls (CX-z0v7 rationale).
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdRows, Response}
  alias Commonplace.Store.CommitStoreClient

  def descriptor do
    %{
      "name" => "bd_show",
      "description" =>
        "Show full detail for one commonplace ticket by id — its fields (title, status, priority, type, owner, needs, done_when, claimed_by, labels, timestamps) plus its description body.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Ticket id, e.g. \"CX-f1c8\"."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(args, _context) when is_map(args) do
    case Map.get(args, "id") do
      id when is_binary(id) and id != "" ->
        show(String.trim(id))

      _ ->
        {:error, :invalid_params, "bd_show requires a non-empty string \"id\" (e.g. \"CX-f1c8\")."}
    end
  end

  defp show(id) do
    with {:ok, root} <- BdRows.resolve_root(),
         {:ok, issue} <- BdRoute.call(Commonplace.Bd.Issue, :show, [root, id, CommitStoreClient]) do
      description = fetch_description(root, id)
      fields = issue_to_json(issue, description)
      {:ok, Response.text(summary(fields, description), fields)}
    else
      {:error, :not_found} ->
        {:error, :invalid_params, "bd_show: ticket #{inspect(id)} not found."}

      {:error, reason} ->
        {:error, :invalid_params, "bd_show failed: #{inspect(reason)}"}

      other ->
        {:error, :invalid_params, "bd_show failed: #{inspect(other)}"}
    end
  end

  # Description is best-effort: a ticket with no description body still
  # renders its fields rather than failing the whole call.
  defp fetch_description(root, id) do
    case BdRoute.call(Commonplace.Bd.Issue, :description, [root, id, CommitStoreClient]) do
      {:ok, text} when is_binary(text) -> text
      _ -> ""
    end
  end

  defp issue_to_json(issue, description) do
    %{
      "id" => issue.id,
      "title" => issue.title,
      "status" => issue.status,
      "priority" => issue.priority,
      "type" => issue.type,
      "owner" => issue.owner,
      "needs" => issue.needs,
      "done_when" => issue.done_when,
      "claimed_by" => issue.claimed_by,
      "labels" => issue.labels,
      "created_at" => issue.created_at,
      "updated_at" => issue.updated_at,
      "description" => description
    }
  end

  defp summary(fields, description) do
    needs =
      case fields["needs"] do
        [] -> "(none)"
        needs -> inspect(needs)
      end

    """
    #{fields["id"]}  #{fields["title"]}
    status:     #{fields["status"]}
    priority:   #{fields["priority"]}
    type:       #{fields["type"]}
    owner:      #{fields["owner"] || "(none)"}
    claimed_by: #{fields["claimed_by"] || "(none)"}
    needs:      #{needs}
    done_when:  #{fields["done_when"]}
    labels:     #{format_labels(fields["labels"])}
    created:    #{fields["created_at"] || "(unknown)"}
    updated:    #{fields["updated_at"] || "(unknown)"}

    #{description_block(description)}
    """
    |> String.trim_trailing()
  end

  defp format_labels([]), do: "(none)"
  defp format_labels(labels) when is_list(labels), do: Enum.join(labels, ", ")
  defp format_labels(other), do: inspect(other)

  defp description_block(""), do: "(no description)"
  defp description_block(description), do: description
end
