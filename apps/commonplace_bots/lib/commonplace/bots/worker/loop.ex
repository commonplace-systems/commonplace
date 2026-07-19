defmodule Commonplace.Bots.Worker.Loop do
  @moduledoc """
  The cave-diver loop — drives the Anthropic Messages API
  tool-use round-trip with hard caps on calls, output tokens, and
  wall-clock time.

  ## Shape

  A "turn" in this loop is one HTTP request to the Messages API.
  The loop builds the initial system+user message pair, then on
  each iteration — *before* issuing a request — checks three
  cumulative budgets in order. Any one already exhausted ends the
  loop immediately without another POST:

    1. Wall-clock elapsed ≥ `max_wall_ms` → `{:cap_hit, :wall_clock}`.
    2. Calls already made ≥ `max_calls` → `{:cap_hit, :calls}`.
    3. Output tokens already spent ≥ `max_output_tokens` →
       `{:cap_hit, :output_tokens}`. This is the *cumulative* token
       cap, summed across every response so far; contrast
       `"max_tokens"` below, which is one *single* response
       overrunning the per-call ceiling we asked for.

  If all three have headroom it POSTs the current message list +
  tool definitions + the *remaining* output-token budget (as that
  request's `max_tokens`), then examines `stop_reason`:

    * `"end_turn"` → loop exits with `{:ok, :end_turn}`. Any
      `text` content in the final assistant message is
      informational only; tool side-effects already happened.
    * `"tool_use"` → for each `tool_use` block in the response,
      dispatch via `Worker.Tools.dispatch/3`, build a matching
      `tool_result` block, append `assistant`+`user` messages
      to the running list, and loop.
    * `"max_tokens"` → `{:cap_hit, :max_tokens}`. The model hit
      the per-call ceiling we sent on this one request — distinct
      from the cumulative `:output_tokens` cap in step 3.
    * anything else → `{:error, {:unexpected_stop, reason}}`.

  ## Tool result on tool errors

  Tool failures (`{:error, reason}` from a tool module) are
  returned to the model as a `tool_result` block with
  `is_error: true` so the model can react (apologize, try a
  different tool, give up) rather than the loop blowing up.

  An *infrastructure* error (transport failure, malformed response
  shape) is different — it is never surfaced to the model, and ends
  the loop with `{:error, {:client_failure, reason}}`. The one
  exception is the retryable-overload subset, which gets a single
  model fallback in first (see below).

  ## Model fallback on overload (CX-hl7j)

  When the client function returns `{:error, reason}` the loop
  gets ONE rescue attempt before giving up, but only when all of:

    * the error is an overload/unavailable HTTP status —
      `529 Overloaded`, `503 Service Unavailable`, `502 Bad Gateway`;
    * a `fallback_model` is configured and differs from the model
      currently in use; and
    * no fallback has happened yet this run (one swap, never a chain).

  When all three hold, the loop swaps `active_model` to the
  fallback and retries the *same* iteration — same message list,
  and no budget is consumed (a failed POST never counted a call,
  since the call/token counters only advance on a successful
  response). Any other error, or a second failure after the swap,
  terminates with `{:error, {:client_failure, reason}}`.

  This is one cheap insurance retry against transient provider
  overload — a single hop to a secondary/cheaper model — not a
  resilience layer: no exponential backoff, no repeated attempts.

  ## State

  Loop state is a plain map; not a GenServer. The Task running
  the loop owns it.
  """

  alias Commonplace.Bots.Agenda
  alias Commonplace.Bots.Worker.Tools
  alias Commonplace.Store.CommitStoreClient

  @type state :: %{
          room: String.t(),
          entity: Commonplace.Bots.Entity.t(),
          event: map(),
          config: %{
            max_calls: pos_integer(),
            max_output_tokens: pos_integer(),
            max_wall_ms: pos_integer(),
            model: String.t()
          },
          client_fn: (map() -> {:ok, map()} | {:error, term()}),
          tools_module: module(),
          signing_context: Commonplace.Crypto.SigningContext.t() | nil,
          allowlist: [String.t()],
          mud_ctx: Commonplace.Bots.MudContext.t() | nil,
          opts: keyword()
        }

  @spec run(state()) :: Commonplace.Bots.Worker.outcome()
  def run(state) do
    started_at = System.monotonic_time(:millisecond)
    messages = initial_messages(state)
    tools = state.tools_module.tool_defs(state)

    loop(state, messages, tools, %{
      calls_remaining: state.config.max_calls,
      output_tokens_used: 0,
      started_at: started_at,
      active_model: state.config.model,
      fell_back: false
    })
  end

  defp loop(state, messages, tools, budget) do
    cond do
      wall_clock_exceeded?(state, budget) ->
        {:cap_hit, :wall_clock}

      budget.calls_remaining <= 0 ->
        {:cap_hit, :calls}

      budget.output_tokens_used >= state.config.max_output_tokens ->
        {:cap_hit, :output_tokens}

      true ->
        request = build_request(state, messages, tools, budget)

        case state.client_fn.(request) do
          {:ok, response} ->
            handle_response(state, messages, tools, budget, response)

          {:error, reason} ->
            case maybe_fall_back(state, budget, reason) do
              {:fallback, new_budget} ->
                loop(state, messages, tools, new_budget)

              :no_fallback ->
                {:error, {:client_failure, reason}}
            end
        end
    end
  end

  # CX-hl7j: on a retryable Anthropic error (HTTP 529 Overloaded,
  # 503 Service Unavailable, 502 Bad Gateway) AND not already
  # fallen back, swap the active model to the configured fallback
  # and retry the same loop iteration. One retry, no exponential —
  # if the fallback also fails we terminate cleanly.
  defp maybe_fall_back(_state, %{fell_back: true}, _reason), do: :no_fallback

  defp maybe_fall_back(state, budget, {:http_status, code, _}) when code in [502, 503, 529] do
    case state.config.fallback_model do
      nil ->
        :no_fallback

      model when model == budget.active_model ->
        # Already using the fallback model as the primary —
        # nothing to fall back to.
        :no_fallback

      fallback ->
        :telemetry.execute(
          [:commonplace, :bots, :worker, :model_fell_back],
          %{system_time: System.system_time()},
          %{
            from: budget.active_model,
            to: fallback,
            reason: :http_status,
            code: code
          }
        )

        {:fallback, %{budget | active_model: fallback, fell_back: true}}
    end
  end

  defp maybe_fall_back(_state, _budget, _reason), do: :no_fallback

  defp handle_response(state, messages, tools, budget, response) do
    tokens_in = get_in(response, ["usage", "output_tokens"]) || 0

    budget = %{
      budget
      | calls_remaining: budget.calls_remaining - 1,
        output_tokens_used: budget.output_tokens_used + tokens_in
    }

    case Map.get(response, "stop_reason") do
      "end_turn" ->
        {:ok, :end_turn}

      "max_tokens" ->
        {:cap_hit, :max_tokens}

      "tool_use" ->
        assistant_msg = %{"role" => "assistant", "content" => Map.get(response, "content", [])}
        tool_uses = collect_tool_uses(response)
        state_with_budget = Map.put(state, :budget_snapshot, snapshot_budget(state, budget))
        tool_results = Enum.map(tool_uses, &dispatch_tool(state_with_budget, &1))
        user_msg = %{"role" => "user", "content" => tool_results}
        loop(state, messages ++ [assistant_msg, user_msg], tools, budget)

      other ->
        {:error, {:unexpected_stop, other}}
    end
  end

  defp collect_tool_uses(response) do
    response
    |> Map.get("content", [])
    |> Enum.filter(fn block -> Map.get(block, "type") == "tool_use" end)
  end

  defp dispatch_tool(state, %{"id" => id, "name" => name, "input" => input}) do
    {result, is_error} =
      case Tools.dispatch(state, name, input || %{}) do
        {:ok, text} -> {text, false}
        :ok -> {"ok", false}
        {:error, reason} -> {inspect_error(reason), true}
      end

    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => result,
      "is_error" => is_error
    }
  end

  defp dispatch_tool(_state, _malformed),
    do: %{"type" => "tool_result", "tool_use_id" => "unknown", "content" => "malformed tool_use",
          "is_error" => true}

  defp inspect_error(reason) when is_binary(reason), do: reason
  defp inspect_error(reason), do: inspect(reason)

  defp build_request(state, messages, tools, budget) do
    remaining_tokens =
      max(state.config.max_output_tokens - budget.output_tokens_used, 1)

    %{
      model: budget.active_model,
      system: state.entity.persona,
      messages: messages,
      tools: tools,
      max_tokens: remaining_tokens
    }
  end

  defp initial_messages(state) do
    [
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "text",
            "text" => build_initial_user_text(state)
          }
        ]
      }
    ]
  end

  # Camillo C3b §10: the heartbeat turn shape. When the dispatcher woke
  # the bot on its own timer (an internally-tagged `"kind" =>
  # "heartbeat"` event — never producible by chat), frame the turn
  # around the bot's agenda and prompt a write-back, rather than the
  # chat "new message" shape. The actual walking / jotting uses C3c
  # tools; here we only SHAPE the turn to read the agenda.
  defp build_initial_user_text(%{event: %{"kind" => "heartbeat"}} = state) do
    items = read_agenda(state)
    agenda_text = render_agenda(items)

    thread =
      if Map.get(state.event, "thread_quiet", true), do: "quiet", else: "active"

    """
    You woke on a heartbeat. Your agenda:
    #{agenda_text}

    The thread is #{thread}. Do one agenda item, or tidy, then update your agenda.
    """
    |> String.trim_trailing()
  end

  defp build_initial_user_text(state) do
    author = Map.get(state.event, "author_path", "human")
    text = Map.get(state.event, "text", "")

    """
    New message in #{state.room}:
    #{author}: #{text}
    """
    |> String.trim_trailing()
  end

  defp read_agenda(state) do
    store = Keyword.get(state.opts || [], :store, CommitStoreClient)

    try do
      Agenda.read(state.entity, store)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp render_agenda([]), do: "(empty)"

  defp render_agenda(items) when is_list(items) do
    items
    |> Enum.map(fn item ->
      case Map.get(item, "text") do
        text when is_binary(text) -> "- #{text}"
        _ -> "- #{Jason.encode!(item)}"
      end
    end)
    |> Enum.join("\n")
  end

  defp wall_clock_exceeded?(state, budget) do
    elapsed = System.monotonic_time(:millisecond) - budget.started_at
    elapsed >= state.config.max_wall_ms
  end

  defp snapshot_budget(state, budget) do
    elapsed = System.monotonic_time(:millisecond) - budget.started_at

    %{
      calls_remaining: budget.calls_remaining,
      output_tokens_remaining:
        max(state.config.max_output_tokens - budget.output_tokens_used, 0),
      wall_ms_remaining: max(state.config.max_wall_ms - elapsed, 0)
    }
  end
end
