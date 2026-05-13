defmodule Commonplace.Bots.Trigger do
  @moduledoc """
  Trigger contract — decides whether a chat event should wake a bot.

  The contract is one function:

      evaluate(event :: map(), entity :: Entity.t())
        :: :skip | :wake | {:wake, priority :: float()}

  v0 ships a single built-in adapter, `Bots.Trigger.Regex`, driven
  by the entity's `trigger.regex` text doc (one pattern per line,
  ANY line matching → `:wake`). v1 will add `Bots.Trigger.Code`
  driven by `trigger.code` (LLM-judge); v2 a DSPy classifier. All
  three implement the same contract so the dispatcher's call site
  doesn't change.

  The dispatcher calls `evaluate/3` with the kind atom (currently
  always `:regex` — `Entity.load/3` only fills `trigger_kind:
  :regex`); future kinds dispatch here.

  ## The event map

  The shape the dispatcher hands in:

      %{
        "verb"        => "post" | "edit" | "delete",
        "room"        => "<room-name>",
        "message_id"  => "<uuid>",
        "author_path" => "alice.usr" | "bob.bot" | …,
        "ts"          => "<iso8601>",
        "text"        => "<resolved message body>"
      }

  The `text` field is resolved by the dispatcher (the magenta event
  carries only metadata; the dispatcher loads the message from
  the `_messages` doc and stamps the body in before calling here).
  Edit and delete events route through the same shape; v0 triggers
  only fire on `"post"`.
  """

  alias Commonplace.Bots.Entity

  @type decision :: :skip | :wake | {:wake, float()}
  @type event :: %{required(String.t()) => term()}

  @spec evaluate(:regex | :code, event(), Entity.t()) :: decision()
  def evaluate(:regex, event, %Entity{} = entity) do
    Commonplace.Bots.Trigger.Regex.evaluate(event, entity)
  end

  def evaluate(:code, _event, _entity) do
    # v0: trigger.code slot exists in the directory shape but
    # is intentionally unimplemented. Returning :skip keeps
    # dispatch routing inert until v1 wires an adapter.
    :skip
  end
end
