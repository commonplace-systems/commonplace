defmodule Commonplace.MCP.Tools.ListTools do
  @moduledoc """
  MCP meta-tool: return the current merged tool catalog (system + CRDT).

  Lets MCP clients reflect on the tool surface at any time, not just
  at session-init. CX-y3q's answer to "most clients don't reload the
  tool list mid-session" — they can call `list_tools` whenever they
  want a fresh view.

  This tool is itself in the system registry but NOT in the
  dispatchable catalog (the catalog `list_tools` returns excludes
  itself + `call_tool`). That keeps the meta-tools always-callable
  but invisible to recursive invocations through `call_tool`.
  """

  alias Commonplace.MCP.Tools.Response

  @doc false
  def descriptor do
    %{
      "name" => "list_tools",
      "description" =>
        "Return the current MCP tool catalog (system + CRDT-defined). The list at session-init can be stale; use this whenever you want a fresh view of available tools, including ones that were added after your session started.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  @doc false
  def run(_args, _context \\ %{}) do
    catalog = Commonplace.MCP.Tools.list()
    {:ok, Response.text("Found #{length(catalog)} tools.", %{"tools" => catalog})}
  end
end
