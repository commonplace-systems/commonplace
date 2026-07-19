defmodule Commonplace.Bots.Worker.Scrollback do
  @moduledoc """
  Camillo C5c-ii (cp-plan #8895) — the scrollback WAKE INJECTION: the read
  side of `Commonplace.Bots.Transcript` (C5c-i). `render/1` is
  `Commonplace.Bots.Worker.Perception`'s sibling — a prose block folded into
  every wake's initial user text, built the SAME way: narrated text (never a
  fabricated `tool_result`), degrading HONESTLY on any failure rather than
  fabricating memory.

  ## Where it sits (both `build_initial_user_text/1` clauses)

  `perception → scrollback → new-stimulus → invitation`. Perception says
  where he is NOW; scrollback says what JUST HAPPENED (the transcript's
  tail, oldest-first, so it reads like conversation, not a stack trace);
  then the fresh stimulus (the chat message that woke this turn, or the
  agenda block on a heartbeat); then the closing invitation line. Both
  chat AND heartbeat wakes get a scrollback — "the hour is yours" should
  know what the previous hour actually did.

  ## Degrade discipline (mirrors `Perception`)

  A missing `state.mud_ctx` or ANY read failure renders the single honest
  line `"You recall nothing."` plus a `Logger.debug` (deliberately quieter
  than `Perception`'s `Logger.warning` — a cold-start empty transcript is
  the ORDINARY case for a bot's very first wake, not a fault worth a
  warning; an actual read exception still gets logged, just at debug).
  Never fabricates a memory that isn't there.

  ## Budgets (v1: whole-turn granularity, newest-first selection)

  Selection walks the transcript NEWEST-turn-first and keeps adding whole
  turns (never splitting one) until adding the NEXT (older) turn would
  push either cumulative bound over:

    * ~2000 tokens, approximated as `chars / 4` (documented approximation —
      cheap and close enough for a soft budget; not a real tokenizer call).
    * ~30 events.

  Whichever bites first stops the walk. The single NEWEST turn is always
  included even if it alone exceeds both bounds (never render nothing when
  there IS history). Once selection stops, the kept turns are rendered
  OLDEST-FIRST — chronological reading order — with an honest truncation
  line at the top when older history was dropped:
  `"…earlier turns have faded from the moment — your transcript holds
  them."` — never silently vanished, always acknowledged.

  ## Rendering (dialogue + acts, one line per event, grouped by turn)

  Each turn gets a light `"— <ts> —"` separator, then one line per event,
  by `"type"` (see `Commonplace.Bots.Worker.Loop`'s "Event taxonomy" for
  where these come from):

    * `"inbound"` → `<author> said: "<text>"`
    * `"reply"` → `You replied: "<text>"` — his own words are INCLUDED,
      deliberately: episodic self-continuity (remembering what *he* said,
      not just what was said to him) is the whole point of this slice.
    * `"act"` / `"move"` → the past-tense sentence C5c-i already composed,
      rendered as-is (capitalized for prose flow).
    * `"tool_call"` → a compact one-liner (`You looked around: <result>`
      for `look`; `You used <tool>: <result>` otherwise) — the truncated
      result C5c-i already stored, never re-fetched or re-truncated here.
    * `"error"` → `You were refused: <reason>` — he sees his own past
      refusals in scrollback too, same as `Loop`'s taxonomy intends.

  ## Stimulus dedupe (identity, NOT text equality — see PIN (d))

  A chat wake's fresh stimulus (`"<author> says: \\"<text>\\""`, rendered
  by `Loop.build_initial_user_text/1` AFTER this block) must render
  EXACTLY ONCE. Because `Transcript.append_turn/2` only ever runs at a
  turn's END (C5c-i), the message that triggers THIS turn structurally
  cannot already be in the transcript when this module reads it — so under
  ordinary single-fire dispatch, no duplication is even possible. The
  dedupe check here exists for the one case where it WOULD be possible: an
  operational replay that re-delivers the identical wake event.

  The comparison is by **identity (`"message_id"`), never by text
  equality**. `Loop.seed_events/1` stamps the triggering event's
  `"message_id"` onto the `"inbound"` transcript event it seeds; this
  module compares the CURRENT wake's `state.event["message_id"]` against
  ONLY the single most-recently-recorded inbound event in the window (the
  newest turn's, if it has one) — never against older turns, and never by
  text. Two DISTINCT messages that happen to carry identical text (a
  genuine human re-send — jes texting "hi" twice) have DIFFERENT
  `message_id`s and are therefore NEVER deduped: both render, each in its
  own place — the first "hi" (and its reply) stays visible in scrollback,
  the second "hi" renders once as the fresh stimulus. Only an literal
  redelivery of the SAME `message_id` — the actual failure mode this
  guards — has its scrollback copy dropped (the fresh-stimulus line already
  covers it once). A missing `message_id` on either side never dedupes
  (fail toward showing more history, never toward hiding it).
  """

  require Logger

  alias Commonplace.Bots.Transcript

  @nil_body_text "You recall nothing."
  @truncation_note "…earlier turns have faded from the moment — your transcript holds them."

  # ~2000 tokens, approximated as chars/4 — a soft budget, not a real
  # tokenizer call (see moduledoc "Budgets").
  @max_tokens 2000
  @chars_per_token 4
  @max_chars @max_tokens * @chars_per_token
  @max_events 30

  @doc """
  Render the scrollback block for this turn's wake. Takes the full Loop
  state (needs `:mud_ctx` to read the transcript, `:event` for the
  stimulus-dedupe identity check, `:entity` to name the bot in the degrade
  log). Never raises — any resolve/read failure degrades to the honest
  nil-recall line plus a logged debug.
  """
  @spec render(map()) :: String.t()
  def render(state) do
    case Map.get(state, :mud_ctx) do
      ctx when is_map(ctx) ->
        try do
          case Transcript.read(ctx) do
            [] -> @nil_body_text
            entries when is_list(entries) -> render_window(entries, state)
          end
        rescue
          e -> degrade(state, Exception.message(e))
        catch
          kind, reason -> degrade(state, "#{kind}: #{inspect(reason)}")
        end

      _no_ctx ->
        degrade(state, :no_mud_ctx)
    end
  end

  defp render_window(entries, state) do
    dedupe_id = stimulus_message_id(state)
    newest_first = Enum.reverse(entries)
    {selected, truncated?} = select_window(newest_first, dedupe_id)

    body = selected |> Enum.map(& &1.prose) |> Enum.join("\n\n")

    if truncated? do
      @truncation_note <> "\n\n" <> body
    else
      body
    end
  end

  # Walks `newest_first` (already newest-turn-first) and keeps prepending
  # each additional (older) turn's rendered prose onto the accumulator —
  # which means the FINAL accumulator ends up OLDEST-first (the first
  # element prepended last is the oldest kept turn), exactly the render
  # order we want, with no separate reverse needed. The single newest turn
  # is unconditionally kept (never render nothing when there IS history);
  # only the newest turn's inbound gets the dedupe check (`dedupe_id`) —
  # every OLDER turn renders its inbound verbatim, unconditionally (see
  # moduledoc "Stimulus dedupe").
  defp select_window([], _dedupe_id), do: {[], false}

  defp select_window([newest | rest], dedupe_id) do
    prose0 = render_turn(newest, dedupe_id)
    events0 = length(Map.get(newest, "events", []))
    init = {[%{prose: prose0}], String.length(prose0), events0, false}

    {selected, _chars, _events, truncated?} =
      Enum.reduce_while(rest, init, fn entry, {acc, chars, events, _} ->
        prose = render_turn(entry, nil)
        p_chars = String.length(prose)
        p_events = length(Map.get(entry, "events", []))
        new_chars = chars + p_chars
        new_events = events + p_events

        if new_chars > @max_chars or new_events > @max_events do
          {:halt, {acc, chars, events, true}}
        else
          {:cont, {[%{prose: prose} | acc], new_chars, new_events, false}}
        end
      end)

    {selected, truncated?}
  end

  defp render_turn(entry, dedupe_id) do
    events = entry |> Map.get("events", []) |> maybe_drop_dedupe(dedupe_id)
    lines = events |> Enum.map(&render_event/1) |> Enum.reject(&is_nil/1)
    Enum.join([turn_header(Map.get(entry, "ts")) | lines], "\n")
  end

  defp turn_header(ts) when is_binary(ts) and ts != "", do: "— #{ts} —"
  defp turn_header(_), do: "—"

  defp maybe_drop_dedupe(events, nil), do: events

  defp maybe_drop_dedupe(events, dedupe_id) do
    {_dropped?, kept} =
      Enum.reduce(events, {false, []}, fn
        %{"type" => "inbound", "message_id" => mid} = _e, {false, acc}
        when not is_nil(mid) and mid == dedupe_id ->
          {true, acc}

        e, {dropped, acc} ->
          {dropped, [e | acc]}
      end)

    Enum.reverse(kept)
  end

  defp render_event(%{"type" => "inbound", "author" => author, "text" => text}) do
    ~s(#{author} said: "#{text}")
  end

  defp render_event(%{"type" => "reply", "text" => text}) do
    ~s(You replied: "#{text}")
  end

  defp render_event(%{"type" => t, "text" => text}) when t in ["act", "move"] do
    capitalize_first(text)
  end

  defp render_event(%{"type" => "tool_call", "tool" => "look", "result" => result}) do
    "You looked around: #{result}"
  end

  defp render_event(%{"type" => "tool_call", "tool" => tool, "result" => result}) do
    "You used #{tool}: #{result}"
  end

  defp render_event(%{"type" => "error", "reason" => reason}) do
    "You were refused: #{reason}"
  end

  # Defensive fallback for an unrecognized/malformed event — never crash the
  # render over one odd entry, just drop that one line.
  defp render_event(_other), do: nil

  defp capitalize_first(text) when is_binary(text) and text != "" do
    String.upcase(String.slice(text, 0, 1)) <> String.slice(text, 1..-1//1)
  end

  defp capitalize_first(text), do: text

  # Only a CHAT wake has a stimulus to dedupe against; a heartbeat wake's
  # event carries no message_id (there's no message).
  defp stimulus_message_id(%{event: %{"kind" => "heartbeat"}}), do: nil
  defp stimulus_message_id(state), do: state |> Map.get(:event, %{}) |> Map.get("message_id")

  defp degrade(state, reason) do
    Logger.debug(
      "Commonplace.Bots.Worker.Scrollback: nil-degrade bot=#{bot_name(state)} reason=#{inspect(reason)}"
    )

    @nil_body_text
  end

  defp bot_name(%{entity: %{name: name}}) when is_binary(name), do: name
  defp bot_name(_), do: "(unknown)"
end
