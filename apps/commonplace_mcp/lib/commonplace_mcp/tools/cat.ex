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

  # CX-re6b round 16: cap content carried in the structured-payload.
  # Cat-of-fork-of-fork was killing the BEAM mid-`IO.write` — most
  # plausibly OOM from megabyte-scale Jason.encode! over the structured
  # block. Capping at 64 KiB keeps the response well under the
  # transport's safe-size envelope; over-sized content is replaced with
  # a {size_bytes, truncated, preview} summary so the agent still sees
  # WHAT the doc holds without forcing a multi-MB write.
  @max_content_bytes 65_536
  @preview_bytes 4_096

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

        structured = build_structured(uuid, name, type, content)

        {:ok, Response.text(render_preview(content), structured)}

      :none ->
        {:error, "not found: #{uuid}"}
    end
  end

  def run(_args), do: {:error, :invalid_params, "uuid (string) is required"}

  defp build_structured(uuid, name, type, content) do
    base = %{"uuid" => uuid, "name" => name, "type" => type_to_string(type)}

    case content_size(content) do
      size when size > @max_content_bytes ->
        Map.merge(base, %{
          "size_bytes" => size,
          "truncated" => true,
          "preview" => preview_for(content)
        })

      _ ->
        Map.put(base, "content", content)
    end
  end

  defp content_size(nil), do: 0
  defp content_size(bin) when is_binary(bin), do: byte_size(bin)
  # Approximate non-binary content size via Jason. Iterating through
  # arbitrary CRDT shapes is fine for sizing — we'd render this anyway
  # in the preview branch.
  defp content_size(other) do
    case Jason.encode(other) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _} -> @max_content_bytes + 1
    end
  end

  defp preview_for(nil), do: "(empty)"
  defp preview_for(bin) when is_binary(bin), do: binary_part(bin, 0, min(byte_size(bin), @preview_bytes))

  defp preview_for(other) do
    case Jason.encode(other, pretty: true) do
      {:ok, encoded} -> binary_part(encoded, 0, min(byte_size(encoded), @preview_bytes))
      {:error, _} -> "(unencodable content of #{inspect(other) |> byte_size()} chars)"
    end
  end

  defp type_to_string(nil), do: nil
  defp type_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp render_preview(nil), do: "(empty)"
  defp render_preview(text) when is_binary(text), do: text
  defp render_preview(other), do: Jason.encode!(other, pretty: true)
end
