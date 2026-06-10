defmodule Commonplace.Bots.Worker.Tools do
  @moduledoc """
  Tool registry + dispatch for cave-diver workers.

  Each tool is a module implementing `name/0`, `definition/0`,
  and `call/2`. `definition/0` returns the Anthropic tool-defn
  shape (`%{name, description, input_schema}`); `call/2`
  receives the loop's state and the tool's parsed input, and
  returns `{:ok, text}` | `:ok` | `{:error, reason}`.

  `tool_defs/1` is what the loop hands to the Messages API;
  `dispatch/3` is the dispatch table the loop walks for each
  `tool_use` block.

  ## The tools

  Seven tools are live in the registry (`@tool_modules`) and
  offered to the model on every turn — two writers and five
  readers. All route through the substrate's ordinary read/write
  primitives (see `Commonplace.Bots.Worker`'s "Substrate-pure I/O"
  note); there is no staged rollout left to wire.

    * `post_message` — append a chat message to the room's
      `_messages` doc as the bot.
    * `remember` — append a JSONL line to the bot's
      `memory.jsonl` doc.
    * `read_chat` — read recent messages from the room.
    * `read_memory` — read back the bot's own `memory.jsonl`.
    * `list_files` — list the entries under a directory in the tree.
    * `read_file` — read a text doc's content.
    * `check_turn_remaining` — report this turn's remaining budget
      (calls / output tokens / wall-clock), read from the
      `:budget_snapshot` the loop stamps into `state` before each
      dispatch.

  ## Why a registry instead of a `case`

  Each tool's `definition/0` lives next to its `call/2` so the
  Anthropic schema and the implementation stay in lockstep. A
  single `case "name" -> handler` block in the dispatcher would
  drift over time.
  """

  alias Commonplace.Bots.Worker.Tools.{
    CheckTurnRemaining,
    ListFiles,
    PostMessage,
    ReadChat,
    ReadFile,
    ReadMemory,
    Remember
  }

  @tool_modules [
    PostMessage,
    Remember,
    ReadChat,
    ReadMemory,
    ListFiles,
    ReadFile,
    CheckTurnRemaining
  ]

  @spec tool_defs(map()) :: [map()]
  def tool_defs(_state) do
    Enum.map(@tool_modules, & &1.definition())
  end

  @spec dispatch(map(), String.t(), map()) :: {:ok, String.t()} | :ok | {:error, term()}
  def dispatch(state, name, input) when is_binary(name) and is_map(input) do
    case Enum.find(@tool_modules, fn m -> m.name() == name end) do
      nil -> {:error, "unknown tool: #{name}"}
      mod -> mod.call(state, input)
    end
  end
end
