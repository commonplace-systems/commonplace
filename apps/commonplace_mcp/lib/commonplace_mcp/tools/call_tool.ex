defmodule Commonplace.MCP.Tools.CallTool do
  @moduledoc """
  MCP meta-tool: late-bind dispatch to any current tool by name.

  CX-y3q's answer to "MCP clients register tools only at session-init":
  even when a CRDT-defined tool didn't exist when the agent connected,
  the agent can invoke it now via `call_tool({name, args})`. The
  dispatcher resolves at call time against the live catalog.

  Recursive guard: meta-tools (`call_tool`, `list_tools`) are
  registered in the system surface but NOT in the dispatchable
  catalog. Calling `call_tool({name: "call_tool", ...})` returns
  `:not_found` — recursion can't begin.
  """

  alias Commonplace.MCP.Tools

  @meta_tools ~w(call_tool list_tools)

  @doc false
  def descriptor do
    %{
      "name" => "call_tool",
      "description" =>
        "Late-bind dispatch to any tool currently in the catalog. Use when you want to invoke a tool whose name your client didn't register at session start (e.g. one that was added after your session began). Args: nested {name, args}.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Name of the tool to invoke."
          },
          "args" => %{
            "type" => "object",
            "description" => "Arguments to pass to the tool. Defaults to {}."
          }
        },
        "required" => ["name"]
      }
    }
  end

  @doc false
  def run(args, context \\ %{})

  def run(%{"name" => name}, _context) when name in @meta_tools do
    {:error, :not_found}
  end

  def run(%{"name" => name} = args, context) when is_binary(name) do
    inner_args = Map.get(args, "args", %{})
    Tools.call(name, inner_args, context)
  end

  def run(_args, _context),
    do: {:error, :invalid_params, "name (string) is required"}
end
