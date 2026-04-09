defmodule Commonplace.MCP.Tools.Cat do
  @moduledoc """
  MCP tool: read a blue doc's content as structured data.

  Reconstructs the document from the commit chain and materializes its
  registered content type (text, map, array). Text comes back as a single
  string; map/array come back as JSON-friendly structures.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.MCP.Tools.Response
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  def descriptor do
    %{
      "name" => "cat",
      "description" =>
        "Read a commonplace blue doc's current content. Blue is the converging CRDT document channel. Returns the structured content (text as a string, map/array as JSON). Use this to observe document state.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "uuid" => %{
            "type" => "string",
            "description" => "UUID of the document to read."
          }
        },
        "required" => ["uuid"]
      }
    }
  end

  def run(%{"uuid" => uuid}) when is_binary(uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} ->
        type = ContentType.get_type(doc)
        content = ContentType.get_content(doc)
        name = ContentType.get_meta(doc, "_name")

        {:ok,
         Response.text(
           render_preview(content),
           %{"uuid" => uuid, "name" => name, "type" => type_to_string(type), "content" => content}
         )}

      :none ->
        {:error, "not found: #{uuid}"}
    end
  end

  def run(_args), do: {:error, :invalid_params, "uuid (string) is required"}

  defp type_to_string(nil), do: nil
  defp type_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp render_preview(nil), do: "(empty)"
  defp render_preview(text) when is_binary(text), do: text
  defp render_preview(other), do: Jason.encode!(other, pretty: true)
end
