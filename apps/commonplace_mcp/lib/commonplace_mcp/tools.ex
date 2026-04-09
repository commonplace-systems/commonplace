defmodule Commonplace.MCP.Tools do
  @moduledoc """
  Registry of MCP tools exposed by the commonplace server.

  `list/0` returns the tool catalog for `tools/list`. `call/2` dispatches a
  `tools/call` request to the right implementation module. Each tool lives in
  its own module under `Commonplace.MCP.Tools.*` and implements a single
  `run/1` function returning `{:ok, result}` / `{:error, …}`.

  Return-tuple conventions mirror `Server.handle/2`:

    * `{:ok, result_map}`          — tool succeeded
    * `{:error, :not_found}`       — no tool by that name is registered
    * `{:error, :invalid_params, detail}` — tool rejected its arguments
    * `{:error, reason}`           — anything else (mapped to internal_error)
  """

  alias Commonplace.MCP.Tools.Fork, as: ForkTool
  alias Commonplace.MCP.Tools.SendMagenta, as: SendMagentaTool
  alias Commonplace.MCP.Tools.TailRed, as: TailRedTool
  alias Commonplace.MCP.Tools.Cat, as: CatTool
  alias Commonplace.MCP.Tools.Write, as: WriteTool

  @registry %{
    "fork" => ForkTool,
    "send_magenta" => SendMagentaTool,
    "tail_red" => TailRedTool,
    "cat" => CatTool,
    "write" => WriteTool
  }

  @doc "Return the tool catalog (list of %{name, description, inputSchema})."
  def list do
    @registry
    |> Map.values()
    |> Enum.map(& &1.descriptor())
    |> Enum.sort_by(& &1["name"])
  end

  @doc "Dispatch a tools/call request to the implementation."
  def call(name, arguments) when is_binary(name) and is_map(arguments) do
    case Map.fetch(@registry, name) do
      {:ok, mod} -> mod.run(arguments)
      :error -> {:error, :not_found}
    end
  end

  def call(_name, _arguments), do: {:error, :not_found}
end
