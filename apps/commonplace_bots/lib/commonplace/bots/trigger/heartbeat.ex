defmodule Commonplace.Bots.Trigger.Heartbeat do
  @moduledoc """
  Heartbeat trigger adapter (Camillo C3b).

  A heartbeat event is the dispatcher waking a bot on its own timer,
  NOT a chat message. Its decision is intentionally cheap and does not
  consult the bot's `trigger.regex` at all:

    * `:skip` — when the agenda is empty **and** the thread is quiet.
      There is nothing pending to do and nothing new to react to, so
      spending an LLM call would be waste. (The dispatcher still beats
      the bot's presence on a `:skip` tick — a resting bot stays alive.)
    * `:wake` — otherwise (a non-empty agenda OR an active thread).

  The two inputs are resolved by the dispatcher *before* the call and
  stamped onto the event as `"agenda_empty"` and `"thread_quiet"`
  (both booleans). This keeps the adapter pure and avoids threading
  store/room handles down into the trigger layer. Absent keys default
  to the conservative "nothing to do" side (empty / quiet → skip).

  This adapter is only ever reached for events the dispatcher tagged
  `"kind" => "heartbeat"` internally — a property a chat message can
  never forge (see `Commonplace.Bots.Dispatcher`).
  """

  alias Commonplace.Bots.Entity

  @spec evaluate(map(), Entity.t()) :: :skip | :wake
  def evaluate(%{} = event, %Entity{}) do
    agenda_empty = Map.get(event, "agenda_empty", true)
    thread_quiet = Map.get(event, "thread_quiet", true)

    if agenda_empty and thread_quiet do
      :skip
    else
      :wake
    end
  end

  def evaluate(_event, _entity), do: :skip
end
