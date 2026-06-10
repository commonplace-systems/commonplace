defmodule Commonplace.MCP.Tools.CallTool do
  @moduledoc """
  MCP meta-tool: late-bind dispatch to any current tool by name.

  CX-y3q's answer to "MCP clients register tools only at session-init":
  even when a CRDT-defined tool didn't exist when the agent connected,
  the agent can invoke it now via `call_tool({name, args})`. The
  dispatcher resolves at call time against the live catalog.

  Recursion guard: `call_tool` is itself a normal, *dispatchable*
  tool in the catalog — session-init clients must be able to see and
  invoke it (that's the whole point). The guard against it invoking
  itself, or `list_tools`, lives here at call time: `run/2` returns
  `:not_found` for any inner `name` that is a meta-tool (`call_tool`,
  `list_tools`), so a `call_tool({name: "call_tool", …})` bounce never
  begins. It is NOT enforced by hiding the meta-tools from the catalog
  (they are visible and directly callable). This is the same guard
  `Commonplace.MCP.Tools` documents living "at call time, in
  `CallTool.run/2`."
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
