defmodule Commonplace.MCP.Tools.Fork do
  @moduledoc """
  MCP tool: fork a document subtree by DAG-branching from an existing UUID.

  Delegates to `Commonplace.CommandRouter.fork/1` so the invocation is
  observable on the `__commands` magenta topic + red audit chain.
  """

  alias Commonplace.CommandRouter
  alias Commonplace.MCP.Tools.Response

  def descriptor do
    %{
      "name" => "fork",
      "description" =>
        "DAG-branch a commonplace document subtree. Returns the new root UUID. Used for creating a copy of a directory that you can mutate without affecting the source, with a shared commit ancestor.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "source_uuid" => %{
            "type" => "string",
            "description" => "UUID of the source document to fork from."
          }
        },
        "required" => ["source_uuid"]
      }
    }
  end

  def run(%{"source_uuid" => source_uuid}) when is_binary(source_uuid) do
    case CommandRouter.fork(source_uuid) do
      {:ok, new_uuid} ->
        {:ok, Response.text("Forked: #{new_uuid}", %{"new_uuid" => new_uuid})}

      {:error, reason} ->
        {:error, "fork failed: #{inspect(reason)}"}
    end
  end

  def run(_args), do: {:error, :invalid_params, "source_uuid (string) is required"}
end
