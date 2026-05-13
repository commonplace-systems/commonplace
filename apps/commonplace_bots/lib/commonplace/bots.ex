defmodule Commonplace.Bots do
  @moduledoc """
  Chat-room bot subsystem — entity-as-doc, ephemeral cave-diver workers.

  A *bot* is a directory in the substrate (`<room>/<name>.bot/`), not
  a long-lived Elixir process. The bot's persona, memory, and trigger
  rules live there as documents. Each turn that a bot takes is a fresh
  cave-diver-shaped LLM worker run: no compaction, tool-use is the
  only output surface, hard caps on calls/tokens/wall-clock, then the
  worker exits.

  ## Components

    * `Commonplace.Bots.Application` — the umbrella app entry point
      and top-level supervisor.
    * `Commonplace.Bots.Dispatcher` — singleton GenServer that
      watches magenta chat events, scans `*.bot/` entries in each
      affected room, evaluates each bot's trigger function, and
      spawns workers when triggers fire.
    * `Commonplace.Bots.Trigger` — the trigger contract
      (`evaluate(event, entity)`) and built-in regex adapter.
    * `Commonplace.Bots.Worker` — pure-Elixir cave-diver loop;
      drives an Anthropic API tool-use loop with hard caps, exposes
      `post_message` / `remember` / read tools scoped to the bot's
      own directory.
    * `Commonplace.Bots.Entity` — the bot doc-tree shape (persona,
      memory, trigger source) and the read/write helpers that
      enforce it.
    * `Commonplace.Bots.RateLimit` — RAM-resident sliding-window
      counters per room and per bot; rebuilt on dispatcher start
      from the last 60s of `__bot_activity`.
    * `Commonplace.Bots.Activity` — the `__bot_activity` substrate
      doc (YArray-of-JSON, same shape as `_messages`) where the
      dispatcher logs trigger decisions (fired / suppressed /
      skipped) for observability.

  See `docs/plans/2026-05-13-bot-design.md` (TBD) for the converged
  design discussion with commonplace-plan.
  """
end
