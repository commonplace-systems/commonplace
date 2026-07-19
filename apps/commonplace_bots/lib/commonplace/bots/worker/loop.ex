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

  ## Turn transcript (Camillo C5c-i, cp-plan #8895)

  The loop is where a turn's events are visible in one place — the initial
  wake, every `tool_use` + its result, in order — so it's also where they're
  collected. An accumulator threads through the internal recursive `loop/4`
  (folded into the budget map as `:events`, prepended in chronological order,
  reversed once at the end) and, after the outcome resolves, the whole batch
  is appended as ONE `Commonplace.Bots.Transcript.append_turn/2` call — one
  RMW per TURN, not per event (the CX-k20z-friendly shape
  `Transcript`'s moduledoc documents). Only when `state.mud_ctx` is present
  (no ctx means no home, means nowhere to write it); a nil ctx degrades
  silently with a `Logger.debug`. An append failure (rejected write, store
  hiccup) is caught, logged, and telemetried — it NEVER alters the turn's
  outcome or crashes the worker; observability must not gate behavior (the
  SAME posture `Commonplace.Bots.Worker`'s presence-flicker and red-log
  side trails already take).

  ### Event taxonomy (cp-plan's, this loop's authoritative encoding)

  Every event is a small map with a `"type"` key:

    * `"inbound"` — the message that woke a CHAT turn: `%{"type" =>
      "inbound", "author" => ..., "text" => ...}`. Heartbeat wakes carry no
      inbound event (there's no author/text — the turn entry's own
      `"wake" => "heartbeat"` field already says so); an empty (`:skip`)
      heartbeat tick never reaches this loop at all — the dispatcher's skip
      decision short-circuits before `Worker.run/4` is even called, so
      that's free, not something this module has to filter.
    * `"reply"` — `post_message`'s text, verbatim: `%{"type" => "reply",
      "text" => ...}`. Distinct from the generic tool-call shape below
      because the reply's TEXT is the substance worth remembering, not a
      call/result pair.
    * `"act"` / `"move"` — a write-shaped tool call rendered as a short
      human-past-tense sentence derived from the tool name + its args
      (`scratch`, `remember`, `update_agenda`, `describe` → `"act"`; `move`
      → `"move"`): `%{"type" => "act", "text" => "you described the
      Foyer"}`. Composed from the CALL's args, not the tool's own return
      text — deterministic and independent of exactly how each tool phrases
      its own confirmation.
    * `"error"` — ANY failed tool call, including a not-allowlisted
      refusal (`Tools.dispatch/3`'s `{:error, "not allowlisted"}`) and an
      ordinary tool error: `%{"type" => "error", "tool" => ..., "reason" =>
      ...}` (reason truncated). He should remember being denied — that's
      how he learns his bounds.
    * `"tool_call"` — the fallback shape for every OTHER (successful,
      read-oriented) tool: `look`, `read_chat`, `read_memory`, `list_files`,
      `read_file`, `check_turn_remaining`: `%{"type" => "tool_call", "tool"
      => ..., "args" => summary, "result" => truncated}` — one event per
      call, carrying both the call and its (~200-char-truncated) result,
      not full dumps.

  Never recorded: the perception block (derived from live state every turn,
  not an event that happened) and a heartbeat `:skip` tick (never reaches
  this module).

  ## Scrollback wake injection (Camillo C5c-ii, cp-plan #8895)

  The seeded `"inbound"` event above carries a `"message_id"` field
  (additive to the C5c-i shape) — it exists so
  `Commonplace.Bots.Worker.Scrollback`'s stimulus-dedupe can compare by
  IDENTITY when it renders the transcript's tail back into a later wake's
  text, never by text equality (see that module's moduledoc "Stimulus
  dedupe" for the full reasoning and the two boundary cases it's built
  from). `build_initial_user_text/1`'s wake text order, both clauses, is
  `perception -> scrollback -> fresh stimulus -> invitation`.
  """

  require Logger

  alias Commonplace.Bots.{Agenda, Transcript}
  alias Commonplace.Bots.Worker.{Perception, Scrollback, Tools}

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

    {outcome, budget} =
      loop(state, messages, tools, %{
        calls_remaining: state.config.max_calls,
        output_tokens_used: 0,
        started_at: started_at,
        active_model: state.config.model,
        fell_back: false,
        events: seed_events(state)
      })

    append_transcript(state, budget.events)

    outcome
  end

  # `budget.events` accumulates in REVERSE chronological order (each new
  # event PREPENDED, O(1)) across the whole turn — every `loop/4` /
  # `handle_response/5` exit returns `{outcome, budget}` so `run/1` above can
  # reach the accumulator no matter which of the several terminal points
  # (cap hit, client failure, end_turn, max_tokens, unexpected stop) the turn
  # ended at. See moduledoc "Turn transcript".
  defp loop(state, messages, tools, budget) do
    cond do
      wall_clock_exceeded?(state, budget) ->
        {{:cap_hit, :wall_clock}, budget}

      budget.calls_remaining <= 0 ->
        {{:cap_hit, :calls}, budget}

      budget.output_tokens_used >= state.config.max_output_tokens ->
        {{:cap_hit, :output_tokens}, budget}

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
                {{:error, {:client_failure, reason}}, budget}
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
        {{:ok, :end_turn}, budget}

      "max_tokens" ->
        {{:cap_hit, :max_tokens}, budget}

      "tool_use" ->
        assistant_msg = %{"role" => "assistant", "content" => Map.get(response, "content", [])}
        tool_uses = collect_tool_uses(response)
        state_with_budget = Map.put(state, :budget_snapshot, snapshot_budget(state, budget))

        {tool_results, new_events} =
          Enum.map_reduce(tool_uses, budget.events, fn tool_use, events_acc ->
            {result_block, events} = dispatch_tool(state_with_budget, tool_use)
            {result_block, Enum.reduce(events, events_acc, fn e, acc -> [e | acc] end)}
          end)

        user_msg = %{"role" => "user", "content" => tool_results}
        loop(state, messages ++ [assistant_msg, user_msg], tools, %{budget | events: new_events})

      other ->
        {{:error, {:unexpected_stop, other}}, budget}
    end
  end

  defp collect_tool_uses(response) do
    response
    |> Map.get("content", [])
    |> Enum.filter(fn block -> Map.get(block, "type") == "tool_use" end)
  end

  # Returns `{tool_result_block, transcript_events}` — the tool_result block
  # feeds the Messages API loop exactly as before; `transcript_events` (see
  # `derive_events/4`) is new (C5c-i) and folded into `budget.events` by the
  # caller.
  defp dispatch_tool(state, %{"id" => id, "name" => name, "input" => input}) do
    normalized_input = input || %{}

    {result, is_error} =
      case Tools.dispatch(state, name, normalized_input) do
        {:ok, text} -> {text, false}
        :ok -> {"ok", false}
        {:error, reason} -> {inspect_error(reason), true}
      end

    block = %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => result,
      "is_error" => is_error
    }

    {block, derive_events(name, normalized_input, result, is_error)}
  end

  defp dispatch_tool(_state, _malformed) do
    block = %{
      "type" => "tool_result",
      "tool_use_id" => "unknown",
      "content" => "malformed tool_use",
      "is_error" => true
    }

    {block, [%{"type" => "error", "tool" => "unknown", "reason" => "malformed tool_use"}]}
  end

  defp inspect_error(reason) when is_binary(reason), do: reason
  defp inspect_error(reason), do: inspect(reason)

  # --- Transcript event derivation (C5c-i) — see moduledoc "Event taxonomy" ---

  # ANY failed call — including a not-allowlisted refusal, which
  # `Tools.dispatch/3` surfaces as this same `{:error, reason}` shape — goes
  # IN as an "error" event. He should remember being denied.
  defp derive_events(name, _input, result, true) do
    [%{"type" => "error", "tool" => name, "reason" => truncate(result)}]
  end

  # `post_message`: the substance worth remembering is the TEXT he sent, not
  # a generic call/result pair.
  defp derive_events("post_message", input, _result, false) do
    [%{"type" => "reply", "text" => Map.get(input, "text", "")}]
  end

  # Write-shaped tools rendered as short past-tense ACTS, derived from the
  # tool name + its OWN args (deterministic — independent of exactly how
  # each tool phrases its own confirmation string).
  defp derive_events("scratch", input, _result, false) do
    page = Map.get(input, "page")
    suffix = if is_binary(page) and page not in ["", "notes"], do: " (#{page})", else: ""
    [%{"type" => "act", "text" => "you jotted a note to your scratch#{suffix}"}]
  end

  defp derive_events("remember", _input, _result, false) do
    [%{"type" => "act", "text" => "you noted something to remember"}]
  end

  defp derive_events("update_agenda", _input, _result, false) do
    [%{"type" => "act", "text" => "you tidied your desk"}]
  end

  defp derive_events("describe", input, _result, false) do
    target = Map.get(input, "target")
    where = if is_binary(target) and target not in ["", "here"], do: target, else: "the room here"
    [%{"type" => "act", "text" => "you described #{where}"}]
  end

  defp derive_events("move", input, _result, false) do
    direction = Map.get(input, "direction", "somewhere")
    [%{"type" => "move", "text" => "you walked #{direction}"}]
  end

  # Fallback: every other (successful) tool — the read-oriented ones (look,
  # read_chat, read_memory, list_files, read_file, check_turn_remaining) —
  # a generic call+truncated-result pair.
  defp derive_events(name, input, result, false) do
    [
      %{
        "type" => "tool_call",
        "tool" => name,
        "args" => summarize_args(input),
        "result" => truncate(result)
      }
    ]
  end

  @summary_arg_bytes 120
  defp summarize_args(input) when is_map(input) do
    input
    |> Jason.encode!()
    |> truncate_string(@summary_arg_bytes)
  end

  defp summarize_args(_input), do: ""

  @result_truncate_bytes 200
  defp truncate(text) when is_binary(text), do: truncate_string(text, @result_truncate_bytes)
  defp truncate(other), do: other |> inspect() |> truncate_string(@result_truncate_bytes)

  defp truncate_string(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…"
    else
      text
    end
  end

  # --- Turn transcript (C5c-i) ---

  # The turn's seed events, in REVERSE order (this accumulator is always
  # prepend-then-reverse-at-the-end) — a CHAT wake seeds the "inbound" event
  # that woke it; a heartbeat wake seeds nothing (no author/text, and the
  # entry's own "wake" field already says "heartbeat").
  defp seed_events(%{event: %{"kind" => "heartbeat"}}), do: []

  defp seed_events(state) do
    author = Map.get(state.event, "author_path", "human")
    text = Map.get(state.event, "text", "")
    # C5c-ii: message_id rides along so Scrollback's stimulus-dedupe can
    # compare by IDENTITY, never by text (see that module's moduledoc).
    message_id = Map.get(state.event, "message_id")
    [%{"type" => "inbound", "author" => author, "text" => text, "message_id" => message_id}]
  end

  defp wake_kind(%{event: %{"kind" => "heartbeat"}}), do: "heartbeat"
  defp wake_kind(_state), do: "chat"

  # Append the WHOLE turn's events as ONE Transcript entry. Only when
  # mud_ctx is present (no home, nowhere to write — degrade silently);
  # rescue-safe so a transcript failure NEVER alters the turn's outcome or
  # crashes the worker (mirrors `Commonplace.Bots.Worker`'s presence-flicker
  # / red-log best-effort posture).
  defp append_transcript(%{mud_ctx: ctx} = state, events) when is_map(ctx) do
    turn = %{"wake" => wake_kind(state), "events" => Enum.reverse(events)}

    try do
      case Transcript.append_turn(turn, ctx) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Loop: transcript append failed: #{inspect(reason)}")
          transcript_append_failed_telemetry(state, reason)
      end
    rescue
      e ->
        Logger.warning("Loop: transcript append raised: #{Exception.message(e)}")
        transcript_append_failed_telemetry(state, Exception.message(e))
    catch
      kind, reason ->
        Logger.warning("Loop: transcript append #{kind}: #{inspect(reason)}")
        transcript_append_failed_telemetry(state, "#{kind}: #{inspect(reason)}")
    end
  end

  defp append_transcript(state, _events) do
    Logger.debug(
      "Loop: no mud_ctx for #{inspect(Map.get(state, :room))} — skipping transcript append"
    )

    :ok
  end

  defp transcript_append_failed_telemetry(state, reason) do
    :telemetry.execute(
      [:commonplace, :bots, :worker, :transcript_append_failed],
      %{system_time: System.system_time()},
      %{room: Map.get(state, :room), bot: entity_name(state), reason: inspect(reason)}
    )
  end

  defp entity_name(%{entity: %{name: name}}), do: name
  defp entity_name(_state), do: nil

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

  # Camillo C3b §10 / C5a: the heartbeat turn shape. When the dispatcher woke
  # the bot on its own timer (an internally-tagged `"kind" =>
  # "heartbeat"` event — never producible by chat), frame the turn
  # around the bot's agenda and prompt a write-back, rather than the
  # chat "new message" shape. The actual walking / jotting uses C3c
  # tools; here we only SHAPE the turn to read the agenda.
  #
  # C5a: the perception block (a prose room snapshot from `state.mud_ctx`,
  # see `Commonplace.Bots.Worker.Perception`) is now the FIRST section of
  # every wake's text — awareness-by-default, not something the bot has to
  # spend a tool call to ask for.
  defp build_initial_user_text(%{event: %{"kind" => "heartbeat"}} = state) do
    perception = Perception.render(state)
    # C5c-ii: heartbeat wakes get scrollback too — "the hour is yours"
    # should know what the previous hour actually did.
    scrollback = Scrollback.render(state)
    items = read_agenda(state)
    agenda_text = render_agenda(items)

    quiet? = Map.get(state.event, "thread_quiet", true)
    thread = if quiet?, do: "quiet", else: "active"

    """
    #{perception}

    #{scrollback}

    You woke on a heartbeat. Your agenda:
    #{agenda_text}

    The thread is #{thread}. Do one agenda item, or tidy, then update your agenda. The hour is yours.
    #{filing_framing(quiet?)}
    """
    |> String.trim_trailing()
  end

  defp build_initial_user_text(state) do
    perception = Perception.render(state)
    # C5c-ii: perception -> scrollback -> the fresh stimulus -> invitation.
    # See Scrollback's moduledoc "Stimulus dedupe" for why the fresh
    # stimulus below never double-renders against scrollback's own tail.
    scrollback = Scrollback.render(state)
    author = Map.get(state.event, "author_path", "human")
    text = Map.get(state.event, "text", "")

    """
    #{perception}

    #{scrollback}

    #{author} says: "#{text}"

    You may take your time: look, walk, consult your notes or agenda, write — and then speak. Or simply speak, if the moment calls for it.
    """
    |> String.trim_trailing()
  end

  # C3d: the agenda lives under the bot's home (a zoned note-meta), resolved
  # from the turn's mud_ctx. A nil mud_ctx (unprovisioned bot) reads empty.
  defp read_agenda(state) do
    try do
      Agenda.read(Map.get(state, :mud_ctx))
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  # C5b (cp-plan #8880) — when the thread is quiet, the framing invites
  # CONSOLIDATION explicitly: distill scratch notes, describe the room(s) they
  # belong to, tidy the desk. A quiet thread is exactly the moment nothing
  # urgent is competing for the hour, so it's the natural cue to file rather
  # than just defer. Silent (no line at all) when the thread is active — an
  # active thread already has its own pull on attention.
  defp filing_framing(true) do
    "\nA quiet thread is a good hour for filing: distill your scratch notes, " <>
      "describe the rooms they belong to, tidy your desk."
  end

  defp filing_framing(false), do: ""

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
      output_tokens_remaining: max(state.config.max_output_tokens - budget.output_tokens_used, 0),
      wall_ms_remaining: max(state.config.max_wall_ms - elapsed, 0)
    }
  end
end
