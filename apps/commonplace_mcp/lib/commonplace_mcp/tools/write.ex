defmodule Commonplace.MCP.Tools.Write do
  @moduledoc """
  MCP tool: update a blue doc's text content, preserving concurrent CRDT edits.

  Delegates to `Commonplace.CommandRouter.write/2` which uses Myers-diff
  on graphemes to compute minimal YText insert/delete ops — so a human
  editing the same doc in a LiveView and an agent calling this tool will
  merge cleanly instead of clobbering each other.
  """

  alias Commonplace.CommandRouter
  alias Commonplace.MCP.Tools.Response

  def descriptor do
    %{
      "name" => "write",
      "description" =>
        "Update a commonplace blue doc's text content. Uses smart merge (Myers diff → YText ops), so concurrent edits from humans or other agents are preserved. Pass the UUID and the new full content as a string. Returns the byte sizes before and after.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "uuid" => %{
            "type" => "string",
            "description" => "UUID of the blue doc to update."
          },
          "content" => %{
            "type" => "string",
            "description" => "The new full text content of the document."
          }
        },
        "required" => ["uuid", "content"]
      }
    }
  end

  def run(%{"uuid" => uuid, "content" => content})
      when is_binary(uuid) and is_binary(content) do
    case CommandRouter.write(uuid, content) do
      {:ok, info} ->
        {:ok,
         Response.text(
           "Wrote #{info["new_bytes"]} bytes to #{uuid} (was #{info["old_bytes"]})",
           info
         )}

      {:error, :not_found} ->
        {:error, "not found: #{uuid}"}

      {:error, reason} ->
        {:error, "write failed: #{inspect(reason)}"}
    end
  end

  def run(_args),
    do: {:error, :invalid_params, "uuid (string) and content (string) are required"}
end
