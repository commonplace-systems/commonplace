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

  ## Phase-4 tools (this commit)

    * `post_message` — append a chat message to the room's
      `_messages` doc as the bot.
    * `remember` — append a JSONL line to the bot's
      `memory.jsonl` doc.

  ## Phase-5 read tools (next phase)

    * `read_chat`
    * `read_memory`
    * `list_files`
    * `read_file`
    * `check_turn_remaining`

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
