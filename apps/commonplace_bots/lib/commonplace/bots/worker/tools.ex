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

  Fourteen tools are live in the registry (`@tool_modules`) — chat/memory
  writers and readers plus the Camillo C3c/C5b/C5c-iii MUD tools (`move`,
  `look`, `scratch`, `describe`, `list_scratch`, `read_scratch`) — but they
  are **not** ambient. As of
  Camillo C3a the registry is DEFAULT-CLOSED per entity: `tool_defs/1`
  offers only the tools in `state.allowlist`, and `dispatch/3` refuses
  any name not in it. The allowlist is the entity's grantor-signed
  charter (see `Commonplace.Bots.Allowlist`), resolved by
  `Commonplace.Bots.Worker`. All route through the substrate's ordinary
  read/write primitives (see `Commonplace.Bots.Worker`'s "Substrate-pure
  I/O" note).

    * `post_message` — append a chat message to the room's
      `_messages` doc as the bot.
    * `remember` — append a JSONL line to the bot's
      `memory.jsonl` doc.
    * `update_agenda` — REPLACE the bot's agenda desk with the given
      item (the heartbeat turn's write-back; C5b fixed this from
      append to replace — see `UpdateAgenda`'s moduledoc).
    * `read_chat` — read recent messages from the room.
    * `read_memory` — read back the bot's own `memory.jsonl`.
    * `list_files` — list the entries under a directory in the tree.
    * `read_file` — read a text doc's content.
    * `check_turn_remaining` — report this turn's remaining budget
      (calls / output tokens / wall-clock), read from the
      `:budget_snapshot` the loop stamps into `state` before each
      dispatch.
    * `move` — walk the bot's `.usr` presence one exit, via the
      shared `World.move_presence/5` motion chokepoint (Camillo C3c).
    * `look` — the bot's read-scoped snapshot of the room it stands
      in (Camillo C3c).
    * `scratch` — jot a note to the bot's own `scratch/<botname>/…`
      wiki scratchpad, bot-signed and namespace-bounded (Camillo C3c).
    * `describe` — rewrite (REPLACE, not append) a room's description in
      the bot's own home zone — memory distilled onto a room's face
      (Camillo C5b, cp-plan #8880).
    * `list_scratch` — list the page names under the bot's own
      `home/scratch/` (Camillo C5c-iii, cp-plan #8892/#8895).
    * `read_scratch` — read a scratch page's text back, size-capped
      (Camillo C5c-iii). The filing loop's READ half: `list_scratch` +
      `read_scratch` let a turn actually consult what it chose to keep,
      before deciding what belongs distilled onto a room via `describe`.

  The six MUD tools act through `state.mud_ctx` — a freshly-resolved
  `Commonplace.Bots.MudContext` the Worker threads PER TURN — never a
  human `PlayerSession`. A nil `mud_ctx` (unprovisioned bot) makes each
  refuse gracefully.

  ## Why a registry instead of a `case`

  Each tool's `definition/0` lives next to its `call/2` so the
  Anthropic schema and the implementation stay in lockstep. A
  single `case "name" -> handler` block in the dispatcher would
  drift over time.
  """

  alias Commonplace.Bots.Worker.Tools.{
    CheckTurnRemaining,
    Describe,
    ListFiles,
    ListScratch,
    Look,
    Move,
    PostMessage,
    ReadChat,
    ReadFile,
    ReadMemory,
    ReadScratch,
    Remember,
    Scratch,
    UpdateAgenda
  }

  @tool_modules [
    PostMessage,
    Remember,
    UpdateAgenda,
    ReadChat,
    ReadMemory,
    ListFiles,
    ReadFile,
    CheckTurnRemaining,
    Move,
    Look,
    Scratch,
    Describe,
    ListScratch,
    ReadScratch
  ]

  @doc """
  Tool definitions to hand the Messages API — filtered to the entity's
  DEFAULT-CLOSED allowlist (Camillo C3a). Only tools whose `name/0` is in
  `state.allowlist` are offered; a nil / empty / missing allowlist offers
  the model NO tools at all. The charter that populates `state.allowlist`
  is grantor-verified upstream (see `Commonplace.Bots.Allowlist`).
  """
  @spec tool_defs(map()) :: [map()]
  def tool_defs(state) do
    allow = allowlist(state)

    @tool_modules
    |> Enum.filter(fn m -> m.name() in allow end)
    |> Enum.map(& &1.definition())
  end

  @doc """
  Dispatch a tool call, gated by the entity's allowlist (Camillo C3a).

  A name that is NOT in `state.allowlist` is refused with a SANITIZED
  `{:error, "not allowlisted"}` — the refusal deliberately does NOT
  enumerate which tools ARE permitted (thin-handle discipline: an
  untrusted model must not learn the shape of the charter from a refusal).
  Only an allowlisted name is looked up in the registry and invoked.
  """
  @spec dispatch(map(), String.t(), map()) :: {:ok, String.t()} | :ok | {:error, term()}
  def dispatch(state, name, input) when is_binary(name) and is_map(input) do
    if name in allowlist(state) do
      case Enum.find(@tool_modules, fn m -> m.name() == name end) do
        nil -> {:error, "unknown tool: #{name}"}
        mod -> mod.call(state, input)
      end
    else
      {:error, "not allowlisted"}
    end
  end

  defp allowlist(state) do
    case Map.get(state, :allowlist) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
