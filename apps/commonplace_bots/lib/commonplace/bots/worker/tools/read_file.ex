defmodule Commonplace.Bots.Worker.Tools.ReadFile do
  @moduledoc """
  `read_file` tool — read a text doc from the bot's own
  directory by name.

  Scoped: only the children declared in `entity.children` are
  reachable. Names containing path separators or `..` are
  rejected outright — there is no nested-path resolution in v0.

  Returns the full text contents. Long files are NOT chunked —
  bots that need windowed reads will land that in a future
  phase along with file metadata (size, mtime).
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  def name, do: "read_file"

  def definition do
    %{
      "name" => "read_file",
      "description" =>
        "Read a file from your own bot directory by name (e.g. 'persona.md', 'trigger.regex').",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Filename inside your bot dir. No path separators or '..'."
          }
        },
        "required" => ["name"]
      }
    }
  end

  def call(state, %{"name" => name}) when is_binary(name) do
    cond do
      not safe_name?(name) ->
        {:error, "read_file: invalid name (no path separators or '..')"}

      not Map.has_key?(state.entity.children, name) ->
        {:error, "read_file: no such file"}

      true ->
        store = Keyword.get(state.opts, :store, CommitStoreClient)
        uuid = Map.fetch!(state.entity.children, name)

        case DocBuilder.reconstruct_snapshot(store, uuid) do
          {:ok, doc} -> {:ok, ContentType.get_content(doc) || ""}
          _ -> {:error, "read_file: unreadable"}
        end
    end
  end

  def call(_state, _), do: {:error, "read_file requires a 'name' field"}

  defp safe_name?(name) do
    not (String.contains?(name, "/") or String.contains?(name, "\\") or
           String.contains?(name, "..") or name == "")
  end
end
