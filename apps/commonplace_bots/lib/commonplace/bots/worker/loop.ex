defmodule Commonplace.Bots.Worker.Loop do
  @moduledoc """
  The cave-diver loop — drives the Anthropic Messages API
  tool-use round-trip with hard caps on calls, output tokens, and
  wall-clock time.

  ## Shape

  A "turn" in this loop is one HTTP request to the Messages API.
  The loop builds the initial system+user message pair, then:

    1. Check the wall-clock budget. Exceeded → `{:cap_hit, :wall_clock}`.
    2. Check the call budget. Exceeded → `{:cap_hit, :calls}`.
    3. POST the current message list + tool definitions + remaining
       output-token budget.
    4. Examine `stop_reason`:
       * `"end_turn"` → loop exits with `{:ok, :end_turn}`. Any
         `text` content in the final assistant message is
         informational only; tool side-effects already happened.
       * `"tool_use"` → for each `tool_use` block in the response,
         dispatch via `Worker.Tools.dispatch/3`, build a matching
         `tool_result` block, append `assistant`+`user` messages
         to the running list, and loop.
       * `"max_tokens"` → `{:cap_hit, :max_tokens}` (per-call
         token ceiling hit; distinct from the cumulative cap).
       * anything else → `{:error, {:unexpected_stop, reason}}`.

  ## Tool result on tool errors

  Tool failures (`{:error, reason}` from a tool module) are
  returned to the model as a `tool_result` block with
  `is_error: true` so the model can react (apologize, try a
  different tool, give up) rather than the loop blowing up.
  Only an *infrastructure* error (HTTP failure, malformed
  response shape) terminates the loop with `{:error, _}`.

  ## State

  Loop state is a plain map; not a GenServer. The Task running
  the loop owns it.
  """

  alias Commonplace.Bots.Worker.Tools

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
      started_at: started_at
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
            {:error, {:client_failure, reason}}
        end
    end
  end

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
        tool_results = Enum.map(tool_uses, &dispatch_tool(state, &1))
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
      model: state.config.model,
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

  defp build_initial_user_text(state) do
    author = Map.get(state.event, "author_path", "human")
    text = Map.get(state.event, "text", "")

    """
    New message in #{state.room}:
    #{author}: #{text}
    """
    |> String.trim_trailing()
  end

  defp wall_clock_exceeded?(state, budget) do
    elapsed = System.monotonic_time(:millisecond) - budget.started_at
    elapsed >= state.config.max_wall_ms
  end
end
