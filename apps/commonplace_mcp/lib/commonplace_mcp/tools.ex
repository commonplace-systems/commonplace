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
  alias Commonplace.MCP.Tools.InvokeViewAction, as: InvokeViewActionTool
  alias Commonplace.MCP.Tools.PresenceInfo, as: PresenceInfoTool

  @registry %{
    "fork" => ForkTool,
    "send_magenta" => SendMagentaTool,
    "tail_red" => TailRedTool,
    "cat" => CatTool,
    "write" => WriteTool,
    "invoke_view_action" => InvokeViewActionTool,
    "presence_info" => PresenceInfoTool
  }

  @doc "Return the tool catalog (list of %{name, description, inputSchema})."
  def list do
    @registry
    |> Map.values()
    |> Enum.map(& &1.descriptor())
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Dispatch a tools/call request to the implementation.

  `context` carries per-session state (e.g. presence_uuid /
  mailbox_uuid / mailbox_topic for the `presence_info` tool). Tools
  that declare `run/2` get it; tools that only declare `run/1` are
  called the old way and ignore context.
  """
  def call(name, arguments, context \\ %{})

  def call(name, arguments, context)
      when is_binary(name) and is_map(arguments) and is_map(context) do
    case Map.fetch(@registry, name) do
      {:ok, mod} ->
        if function_exported?(mod, :run, 2) do
          mod.run(arguments, context)
        else
          mod.run(arguments)
        end

      :error ->
        {:error, :not_found}
    end
  end

  def call(_name, _arguments, _context), do: {:error, :not_found}
end
