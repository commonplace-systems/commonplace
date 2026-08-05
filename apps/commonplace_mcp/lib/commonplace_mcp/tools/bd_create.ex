defmodule Commonplace.MCP.Tools.BdCreate do
  @moduledoc """
  MCP tool (Tier-2 WRITE): create a new ticket in the commonplace
  ticket-DAG.

  CX-6cz3 (tix-authority migration §7): routes the `ticket_create`
  view action through `Commonplace.ViewActionDispatch` on the serve via
  `BdRoute` (one bounded rpc — CX-z0v7 rationale), exactly as
  `bd_add_needs` / `bd_update` / `bd_close` already route theirs. It
  previously called `Commonplace.Bd.Issue.create/4` directly: node-signed
  but UNGATED — the create door the cutover's single-write-path property
  could not survive (design §3 finding 4). Every ticket write now passes
  `Commonplace.Bd.WriteGuard`.

  Carries a `signing_context` from `BdWrite` so the resulting commits are
  signed (enforce-mode denies unsigned writes). See `BdWrite` for the v1
  node-signing story.

  Dependency edges are usually added separately via `bd_add_needs`;
  `needs` defaults to `[]` (initial edges, if given, run the same cycle
  gate).
  """

  alias Commonplace.MCP.Tools.{BdRoute, BdWrite, Response}

  def descriptor do
    %{
      "name" => "bd_create",
      "description" =>
        "Create a new ticket in the commonplace ticket-DAG. Requires a title; type (default \"task\"), priority (default \"p2\"), and description are optional. Dependency edges are normally added afterward with bd_add_needs. Returns the new ticket id and fields.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Ticket title (required)."},
          "type" => %{
            "type" => "string",
            "description" => "Ticket type (default \"task\"): e.g. task, bug, feature, epic."
          },
          "priority" => %{
            "type" => "string",
            "description" => "Priority (default \"p2\"): p0/p1/p2/p3."
          },
          "description" => %{
            "type" => "string",
            "description" => "Optional description body."
          },
          "needs" => %{
            "type" => "array",
            "description" =>
              "Optional list of prerequisite refs. Usually omit and add edges via bd_add_needs.",
            "items" => %{"type" => "object"}
          }
        },
        "required" => ["title"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(args, context) when is_map(args) and is_map(context) do
    case Map.get(args, "title") do
      title when is_binary(title) and title != "" ->
        create(String.trim(title), args, context)

      _ ->
        {:error, :invalid_params, "bd_create requires a non-empty string \"title\"."}
    end
  end

  defp create(title, args, context) do
    with sc when is_struct(sc, Commonplace.Crypto.SigningContext) <-
           BdWrite.signing_context(context) do
      # The verb resolves the bd root itself (same
      # `Commonplace.Workspace.root_uuid/0` every ticket verb uses), so
      # the tool no longer carries one.
      args_map = %{
        "title" => title,
        "type" => Map.get(args, "type", "task"),
        "priority" => Map.get(args, "priority", "p2"),
        "description" => Map.get(args, "description", ""),
        "needs" => Map.get(args, "needs", [])
      }

      dispatch =
        BdRoute.call(Commonplace.ViewActionDispatch, :dispatch, [
          "ticket_create",
          %{args: args_map, signing_context: sc, source: "mcp"}
        ])

      case dispatch do
        {:ok, :tree_mutation, details} ->
          issue = details[:issue] || details["issue"]

          fields = %{
            "id" => issue.id,
            "title" => issue.title,
            "type" => issue.type,
            "priority" => issue.priority,
            "status" => issue.status,
            "done_when" => issue.done_when
          }

          {:ok,
           Response.text(
             "Created #{issue.id}  [#{issue.priority}/#{issue.type}]  #{issue.title}",
             fields
           )}

        {:error, msg} when is_binary(msg) ->
          {:error, :invalid_params, msg}

        other ->
          {:error, :invalid_params, "bd_create failed: #{inspect(other)}"}
      end
    else
      {:error, :no_signing_context} ->
        {:error, :invalid_params, "bd_create failed: no signing context available."}

      {:error, reason} ->
        {:error, :invalid_params, "bd_create failed: #{inspect(reason)}"}
    end
  end
end
