defmodule Commonplace.Bots.Trigger do
  @moduledoc """
  Trigger contract — decides whether a chat event should wake a bot.

  Two layers share the verb "evaluate"; keep them apart:

    * This module is the ROUTER. The dispatcher calls
      `Trigger.evaluate(kind, event, entity)` (**arity 3**) — it
      switches on the kind atom and delegates to the matching
      adapter. This is the only entry point the dispatcher knows.
    * Each ADAPTER implements the contract proper,
      `evaluate(event, entity)` (**arity 2**), returning
      `:skip | :wake | {:wake, priority :: float()}`.

  v0 ships a single built-in adapter, `Bots.Trigger.Regex`, driven
  by the entity's `trigger.regex` text doc (one pattern per line,
  ANY line matching → `:wake`). v1 will add `Bots.Trigger.Code`
  driven by `trigger.code` (LLM-judge); v2 a DSPy classifier. All
  implement the same 2-arity contract, so the router — and the
  dispatcher's single call site — doesn't change as kinds are added.

  The `kind` comes from `entity.trigger_kind`, which `Entity.load/3`
  currently always fills as `:regex`, so `:regex` is the only live
  route today. `evaluate(:code, …)` is already wired but
  intentionally returns `:skip`: the `trigger.code` slot exists in
  the directory shape but no adapter consumes it until v1, so the
  router keeps dispatch inert on that kind rather than crashing on
  an unbuilt adapter.

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
  # Camillo C3b: a heartbeat event is dispatcher-tagged (`"kind" =>
  # "heartbeat"`) and routes to the heartbeat adapter REGARDLESS of the
  # entity's `trigger_kind` — it is a timer wake, not a chat match. This
  # clause is matched on the EVENT's kind (set internally by the
  # dispatcher, never derived from chat content), so no chat message can
  # reach it. See `Commonplace.Bots.Trigger.Heartbeat`.
  def evaluate(_kind, %{"kind" => "heartbeat"} = event, %Entity{} = entity) do
    Commonplace.Bots.Trigger.Heartbeat.evaluate(event, entity)
  end

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
