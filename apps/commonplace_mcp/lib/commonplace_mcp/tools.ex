defmodule Commonplace.MCP.Tools do
  @moduledoc """
  Registry of MCP tools exposed by the commonplace server.

  `list/0` returns the tool catalog for `tools/list`. `call/3`
  dispatches a `tools/call` request to the right implementation.
  Two registries are merged at runtime:

    * **System tools** — the shipped substrate tools
      (`cat`, `fork`, `invoke_view_action`, `send_magenta`,
      `tail_red`, `write`, `presence_info`, `mud_send`, `mud_read`,
      `loom_send`, `loom_read`) plus the meta-tools (`call_tool`,
      `list_tools`). Compile-time, in this module.
    * **CRDT tools** (CX-y3q) — read at runtime from
      `__system/tools/`. Each interface doc declares an MCP-facing
      shape + a magenta address; `Commonplace.MCP.CrdtTools.list/2`
      and `.call/3` handle the dynamic side.

  Precedence: when a CRDT tool name collides with a system tool, the
  system tool wins — silently, in two places. `list/0` drops the
  shadowing CRDT entry from the catalog (the name appears once, as the
  system tool), and `call/3`'s dispatch cond checks both system
  registries before falling through to CRDT tools, so a colliding CRDT
  name is never reached. There is no telemetry on the collision today:
  a CRDT author who reuses a system name simply finds their tool
  invisible and unreachable.

  ## Meta-tools

  `call_tool` and `list_tools` are in the system registry AND in the
  catalog returned by `list/0`. They MUST appear in `tools/list` so
  clients that register tools only at session-init (Claude Code,
  most others) can see and dispatch them — the whole point of the
  late-bind/reflection meta-tools is to be reachable by exactly those
  clients. The recursion guard lives at dispatch time inside
  `Commonplace.MCP.Tools.CallTool.run/2`: name ∈ {"call_tool",
  "list_tools"} returns `:not_found`, breaking recursion before it
  starts. Catalog visibility is unaffected.

  ## Return-tuple conventions

    * `{:ok, result_map}`                 — tool succeeded
    * `{:error, :not_found}`              — no tool by that name
    * `{:error, :invalid_params, detail}` — tool rejected arguments
    * `{:error, {:handler_not_found, p}}` — CRDT tool's handler doc missing
    * `{:error, reason}`                  — anything else (→ internal_error)
  """

  alias Commonplace.MCP.CrdtTools

  alias Commonplace.MCP.Tools.{
    CallTool,
    Cat,
    Fork,
    InvokeViewAction,
    ListTools,
    LoomRead,
    LoomSend,
    MudRead,
    MudSend,
    PresenceInfo,
    SendMagenta,
    TailRed,
    Write
  }

  # All static tools — substrate + meta. Both groups are visible in
  # the catalog returned by `list/0` (session-init clients need to
  # see the meta-tools to invoke them), but the meta-tools live in
  # a separate map so dispatch can recognise them as the recursion-
  # guard surface and so future status (e.g. annotation as
  # `category: "meta"`) is straightforward.
  @substrate_registry %{
    "fork" => Fork,
    "send_magenta" => SendMagenta,
    "tail_red" => TailRed,
    "cat" => Cat,
    "write" => Write,
    "invoke_view_action" => InvokeViewAction,
    "presence_info" => PresenceInfo,
    "mud_send" => MudSend,
    "mud_read" => MudRead,
    "loom_send" => LoomSend,
    "loom_read" => LoomRead
  }

  @meta_registry %{
    "call_tool" => CallTool,
    "list_tools" => ListTools
  }

  # System-tool names a CRDT tool can shadow but never displace.
  @system_names Map.keys(@substrate_registry) ++ Map.keys(@meta_registry)

  @doc """
  Return the merged tool catalog (system substrate + meta + CRDT).

  Meta-tools (`call_tool`, `list_tools`) are included — clients that
  register tools only at session-init must see them to dispatch.
  Recursion guard is at call time, not list time.
  """
  def list do
    static =
      (Map.values(@substrate_registry) ++ Map.values(@meta_registry))
      |> Enum.map(& &1.descriptor())

    crdt =
      case Commonplace.Workspace.root_uuid() do
        {:ok, root_uuid} -> CrdtTools.list(Commonplace.Store.CommitStoreClient, root_uuid)
        _ -> []
      end

    # System tools win on name collision; drop CRDT entries that shadow.
    crdt = Enum.reject(crdt, fn descriptor -> descriptor["name"] in @system_names end)

    (static ++ crdt) |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Dispatch a tools/call request.

  Static system tool wins; falls through to CRDT tool when the name
  isn't in the system registry. Meta-tools (`call_tool`, `list_tools`)
  are reachable through this function AND returned by `list/0` (see
  the "Meta-tools" note in the moduledoc) — the recursion guard is at
  call time, not by hiding them from the catalog.

  `context` carries per-session state (e.g. presence_uuid for
  `presence_info`). Tools declaring `run/2` get it; `run/1`-only
  tools are called the old way.
  """
  def call(name, arguments, context \\ %{})

  def call(name, arguments, context)
      when is_binary(name) and is_map(arguments) and is_map(context) do
    cond do
      mod = Map.get(@substrate_registry, name) -> dispatch_static(mod, arguments, context)
      mod = Map.get(@meta_registry, name) -> dispatch_static(mod, arguments, context)
      true -> dispatch_crdt(name, arguments)
    end
  end

  def call(_name, _arguments, _context), do: {:error, :not_found}

  # CX-k320: load the module before asking which arities it exports.
  # `function_exported?/3` returns false for an unloaded module, and
  # tools live in eager-compiled-but-lazy-loaded application modules.
  # Without ensure_loaded? the first dispatch of a fresh-process or
  # fresh-test-VM session falls back to `run/1` — losing the context
  # map (and silently shipping presence_uuid=nil to a tool that
  # depends on it). Subsequent calls see the loaded module and
  # behave correctly, which is what made the bug
  # order-dependent in meta_tools_test.exs:51.
  defp dispatch_static(mod, arguments, context) do
    _ = Code.ensure_loaded?(mod)

    if function_exported?(mod, :run, 2) do
      mod.run(arguments, context)
    else
      mod.run(arguments)
    end
  end

  defp dispatch_crdt(name, arguments) do
    case Commonplace.Workspace.root_uuid() do
      {:ok, root_uuid} ->
        CrdtTools.call(name, arguments, root_uuid: root_uuid)

      _ ->
        {:error, :not_found}
    end
  end
end
