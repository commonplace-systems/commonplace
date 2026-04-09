defmodule Commonplace.MCP.Resources do
  @moduledoc """
  MCP resource registry.

  Resources in MCP are identified by URIs and can be static (listed via
  `resources/list`) or parameterized templates (listed via
  `resourceTemplates`). The server responds to `resources/read` with a
  list of content entries for the given URI.

  ## Supported URI schemes

    * `tree://<uuid>` — the structured directory listing (schema) of a
      commonplace subtree. `<uuid>` is the document UUID of a directory
      (schema) doc. Returns a JSON tree with names, child UUIDs, and
      types.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @doc "Concrete resources (always-available URIs)."
  def list, do: []

  @doc "Parameterized resource templates."
  def templates do
    [
      %{
        "name" => "tree",
        "uriTemplate" => "tree://{uuid}",
        "description" =>
          "Structured directory listing of a commonplace document subtree. Pass the UUID of the directory (schema) doc after the tree:// scheme.",
        "mimeType" => "application/json"
      }
    ]
  end

  @doc "Read a resource by URI."
  def read("tree://" <> uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} ->
        entries = Schema.list_entries(doc)
        payload = %{"uuid" => uuid, "entries" => Enum.map(entries, &entry_to_map/1)}
        # Include doc metadata if present
        payload =
          case ContentType.get_meta(doc, "_name") do
            nil -> payload
            name -> Map.put(payload, "name", name)
          end

        {:ok,
         [
           %{
             "uri" => "tree://#{uuid}",
             "mimeType" => "application/json",
             "text" => Jason.encode!(payload, pretty: true)
           }
         ]}

      :none ->
        {:error, :not_found}
    end
  end

  def read(_uri), do: {:error, :not_found}

  defp entry_to_map(entry) do
    %{
      "name" => entry.name,
      "node_id" => entry.node_id,
      "type" => to_string(entry.type),
      "sync" => entry.sync
    }
  end
end
