defmodule Commonplace.Bots do
  @moduledoc """
  Chat-room bots expressed as documents, not processes.

  Umbrella-level overview of the `commonplace_bots` app: every
  component and the architectural decisions the subsystem turns on.
  Start here, then follow the named modules below.

  ## The decision this app is built around: entity-as-doc

  A *bot* is **a directory in the substrate** (the CRDT doc tree —
  the shared, conflict-free replicated store at the core of
  Commonplace), `<room>/<name>.bot/`, not a long-lived GenServer. Its
  persona, memory, and trigger rules are documents in that tree
  — alongside every chat message and user home directory. There is no
  registry of active bots, no per-bot process to supervise, no state
  to migrate on deploy. To create a bot, create a directory; to
  delete it, remove the directory; to edit its personality, edit a
  text file. The substrate is the single source of truth: a human
  editing `persona.md` in the web UI and a bot rewriting its own
  memory are the same kind of write.

  The `.bot` suffix is load-bearing: an *honorific extension*
  reserved by `Commonplace.Tree.Schema`. Four such suffixes form a
  closed legend — each tags *what kind of actor a tree entry is* by
  name alone:

    * `.usr` — a human actor (e.g. `bob.usr`, a person's home dir).
    * `.exe` — a running process / live presence (e.g. a worker's
      transient `alice-3f2a.exe`; see the presence note below).
    * `.who` — a generic actor, used when neither human nor process
      fits.
    * `.bot` — a chat bot, *this app's subject*: a directory of docs.

  These four tags reappear throughout this overview; each later
  mention references this legend, not a new concept. A suffix is
  readable without deserializing a binary schema entry — which matters
  because humans (in the web UI) and bots (rewriting their own files)
  write the same tree and must agree on what a bot *is* by name alone.
  The full tradeoff is examined in `Commonplace.Bots.Entity`.

  ### Why not long-lived bot processes?

  The obvious design is "one GenServer per bot, subscribed to its
  rooms, holding conversation state." Three reasons to reject it:

    * **State drift.** A process holding conversation context drifts
      from the substrate. Two sources of truth produce reconciliation
      bugs. Entity-as-doc has exactly one.
    * **Lifecycle weight.** Thousands of mostly-idle bots become
      thousands of mostly-idle processes to supervise, restart, and
      migrate. Directories cost nothing when idle.
    * **Crash semantics.** A crashed bot-process loses its in-memory
      turn. A crashed *worker* (see below) loses nothing durable —
      its memory was already in the substrate.

  ## The delivery layer: magenta

  Everything below depends on one transport, so define it once.
  *Magenta* (`Commonplace.Dataflow.Magenta`) is the substrate's
  ephemeral pub/sub layer: fire-and-forget broadcasts, each a
  `%Magenta{type, source, payload, timestamp}` envelope, sent on
  path-based topics over `Phoenix.PubSub`. Delivery is **real-time
  push** — when chat commits a message it broadcasts a magenta event
  and every subscribed process receives `{:magenta, topic, msg}`
  immediately; nobody polls. A non-subscribed topic costs nothing.

  Two alternatives were rejected: (1) **polling the `_messages` doc**
  — simple, but adds latency and load proportional to room count even
  when idle; (2) a **dedicated bot message bus** — a second transport
  alongside the one chat already runs on. Magenta wins because it is
  *already the substrate's command/notification spine* (the same layer
  the orchestrator and presence use), so the bots app subscribes
  rather than builds. The durable counterpart — when an ephemeral
  magenta stream needs an auditable history — is
  `Commonplace.Dataflow.RedLog` (the magenta→red onramp); the worker
  uses that pairing for its private trail, described below.

  ## The second decision: ephemeral cave-diver workers

  When a bot takes a turn, that turn is a fresh, short-lived LLM
  worker run — a "cave diver": in, one unit of work, out, done.
  Concretely a worker:

    * has **no compaction** (each turn starts a fresh message list)
      and **no persistent process state** — inter-turn memory lives in
      the bot's `memory.jsonl` doc, never in the BEAM;
    * uses **tool calls as its only output surface** — to post to
      chat it calls `post_message`; every side effect is an explicit
      tool;
    * runs under **hard caps** on API calls, output tokens, and
      wall-clock, then exits with a structured outcome.

  Memory is a `.jsonl` doc rather than process state because a turn
  is fully reconstructible from the substrate.

  ### Turns and fetching

  A **turn** is the *entire worker run* for one fired trigger —
  the whole cave-dive, not a single API round-trip. Inside that run
  the worker drives a multi-step Anthropic tool-use *loop* (model
  speaks, calls a tool, sees the result, speaks again), ending when
  the model emits `end_turn` or a cap fires. Context arrives in two
  phases *within* that one turn:

    * **Pre-fetch** (before the loop's first model call): the
      dispatcher hands the worker the triggering message's text in
      the opening user turn. This is the only context guaranteed
      present — a single message, not the room.
    * **Active-fetch** (mid-loop, on demand): anything beyond that —
      fuller room scrollback, prior memory — the worker fetches by
      calling a tool (`read_chat`, `read_memory`); it holds no
      standing buffer between turns. "Re-reads the room" means an
      explicit tool call inside the run, not pre-loaded state.

  The **fetch boundary** is the *whole doc*: `read_chat` reconstructs
  the room's `_messages` document via `Commonplace.Tree.DocBuilder`
  and returns all entries — no time window or last-N slice is imposed
  at the substrate layer; the worker's hard caps bound how much it
  pulls. `read_memory` likewise reads the bot's entire `memory.jsonl`.

  `memory.jsonl` is append-only, one JSON object per line, written
  by the `remember` tool. v0 entry shape: `{"ts": <iso8601>,
  "text": <string>, "source_msg_id": <id-or-null>}` (`kind` is a
  reserved key, not yet emitted). The doc-tree contract for the
  whole `*.bot/` directory is defined in `Commonplace.Bots.Entity`;
  the line schema lives in `Commonplace.Bots.Worker.Tools.Remember`.

  ## Components (the cast, in dependency order)

    * `Commonplace.Bots.Application` — OTP application and top-level
      supervisor. Boots one_for_one: `WorkerSupervisor`
      (`Task.Supervisor` for ephemeral workers), `RateLimit`, and
      `Dispatcher`. Umbrella infra, not an orchestrator-compiled
      process — sibling to `Commonplace.Sync.Agent`.

    * `Commonplace.Bots.Dispatcher` — the singleton GenServer at the
      center of the story. Subscribes to magenta `chat:<room>:events`,
      and on each human-authored `"post"`: loads the message text,
      enumerates the room's `*.bot/` entries, evaluates each bot's
      trigger, and spawns a worker when one fires (subject to rate
      limits). The only module that touches all the others.

    * `Commonplace.Bots.Entity` — the doc-tree *shape*. Defines what
      a well-formed `*.bot/` directory contains (`persona.md`,
      `memory.jsonl`, `trigger.regex`, optional `bot.json`) and the
      `load/3` / `list_in_room/2` read helpers the dispatcher uses
      to turn a directory UUID into an `%Entity{}`.

    * `Commonplace.Bots.Trigger` — the trigger *contract*:
      `evaluate(kind, event, entity) :: :skip | :wake | {:wake,
      priority}`. This is a **kind-dispatch behind one call site**:
      the dispatcher always calls `Trigger.evaluate/3`; the `kind`
      atom selects the strategy, so adding a trigger type never
      touches the dispatcher. v0 dispatches `:regex` to
      `Commonplace.Bots.Trigger.Regex` (one pattern per line, any
      match wakes). `:code` is the **LLM-judge** strategy: a cheap
      model is asked "should this bot wake?" and answers wake/skip.
      Both — and any future classifier — plug into the same
      `evaluate/3` switch; the dispatcher never changes.

    * `Commonplace.Bots.Worker` — the cave-diver itself. `run/4`
      drives the Anthropic Messages API tool-use loop (via
      `Commonplace.Bots.Worker.Loop`), enforces the caps, flickers
      an `.exe` presence entity while alive, and writes the bot's
      private `__red_log`. The `__red_log` is the bot's durable event
      ledger — a `Commonplace.Dataflow.RedLog` document (the
      magenta→red onramp from the delivery-layer section) — recording
      one entry per turn: which room, which message, and the structured
      outcome. It is the bot's *cross-room* trail, distinct from the
      room-scoped `__bot_activity` doc below.

      The presence flicker is *transient*, and why it must be uniquely
      named per turn is an architectural hazard worth stating before
      the fix: an `.exe` is a *live presence* claim, but a worker can
      die mid-turn (cap, error, crash). A fixed name like `alice.exe`
      reused every turn would leave a **stale presence** — a ghost
      entry asserting "alice is running" after the worker is gone —
      and two overlapping turns would collide on the same path. The
      fix: a uniquely-named `<bot>-<shortid>.exe` is minted on entry
      and unconditionally removed on exit via an `after` block
      (success, cap, error, or crash). A leak is scoped to one dead
      id; overlapping turns never collide. Every run ends in a
      structured `outcome()`: `{:ok, :end_turn}` (model said done),
      `{:cap_hit, which}` where `which ∈ {:calls, :output_tokens,
      :wall_clock, :max_tokens}`, or `{:error, reason}`; an unmatched
      crash is normalized to an error outcome. That outcome is what
      telemetry carries back to the dispatcher — a real-time
      `:telemetry` *push*: the worker emits a `:worker, :finished`
      event and a handler the dispatcher attached at boot fires
      synchronously, placing the outcome in the dispatcher's mailbox
      (the dispatcher never polls for completions). It is also what
      the red log records. The worker's tools (`post_message`,
      `remember`, `read_chat`, `read_memory`, `list_files`,
      `read_file`) all route through the same substrate primitives the
      web UI uses — no bot-only fast lanes.

    * `Commonplace.Bots.RateLimit` — RAM-resident GenServer holding
      three counter classes: per-room sliding-window post budget
      (default 3 / 60s), per-bot cooldown (default 10s), and
      per-room + global concurrency caps (2 / 3). Counters live in
      RAM, not the substrate, for a storage-cost reason: the substrate
      is an append-only commit DAG (every write is a new immutable
      node linked to its parents; nothing is overwritten in place).
      Persisting a counter would mean a commit per increment — N posts
      produce N permanent history nodes to track a number meaningful
      only for the next 60 seconds. RAM increments are free and leave
      the durable history for things worth remembering. The cost:
      counters are lost on restart, so on dispatcher boot they are
      reseeded from recent posts in `_messages`
      (`seed_from_history/2`).

    * `Commonplace.Bots.Activity` — the room's `__bot_activity` doc:
      an append-only YArray-of-JSON (the CRDT list type — a
      collaboratively-editable ordered sequence), same shape as
      `Chat.Messages`' `_messages`. The *audit* surface
      (fired / suppressed / completed / cap_hit / error) that
      complements RateLimit's ephemeral counters. Durable
      observability lives here; live counters live in RateLimit.

  ## A turn, traced end to end

  `#general` contains `alice.bot/` whose `trigger.regex` is
  `(?i)@alice\\b`; human `bob.usr` posts "hey @alice what's the
  weather".

    1. The chat layer commits the message to `_messages` and
       broadcasts `{:magenta, "magenta:chat:general:events", …}`.
    2. `Dispatcher.handle_chat_event/2` sees verb `"post"`, author
       `bob.usr`. `bot_authored?/1` is false, so it routes the post.
       Had the author been a `.bot`, the post would be dropped here,
       before bot enumeration — the hard **no-bots-reply-to-bots**
       rule. Two bots that each trigger on the other would ping-pong
       without a human in the loop, amplifying into runaway chat
       volume and API cost. RateLimit would eventually throttle it,
       but the cheaper, certain fix is to never let bot posts wake
       bots at all. (Author-level loop prevention is this one strict
       guard; everything *else* about bot frequency is rate-limited,
       not hard-blocked.)
    3. It loads the body text from `_messages`, then calls
       `Entity.list_in_room/2`, returning `alice.bot`.
    4. `Entity.load/3` reconstructs `alice.bot/`, validates required
       children, and returns `%Entity{trigger_kind: :regex,
       trigger_source: "(?i)@alice\\b", …}`.
    5. `Trigger.evaluate(:regex, event, entity)` runs the regex
       against `"hey @alice what's the weather"` → matches → `:wake`.
    6. The dispatcher calls `RateLimit.acquire("general", "alice")`.
       If `#general` already had 3 bot posts in the last 60s →
       `{:throttled, :per_room_burst}`. The dispatcher logs
       `"suppressed"` to `__bot_activity` via `Activity` and stops.
       No worker runs. (On `:ok`, the concurrency counters are held
       until `release/2`.)
    7. On the happy path, `Dispatcher.spawn_worker/4` starts
       `Worker.run/4` under `WorkerSupervisor`, wrapped so
       `RateLimit.release/2` fires in an `after` block regardless of
       how the worker exits.
    8. The worker reads chat and memory, calls `post_message` ("It's
       sunny."), the model emits `end_turn`, and the worker exits
       `{:ok, :end_turn}`. A `:worker, :finished` telemetry event
       reaches the dispatcher, which logs `"completed"` to
       `__bot_activity`. Had the worker burned its call budget instead,
       it exits `{:cap_hit, :calls}` (logged `"cap_hit"`); a raised
       exception or trigger-evaluation failure becomes `{:error,
       reason}` (logged `"error"`). No outcome posts an apology to
       chat — failure is visible only in the audit trail.

  The key non-obvious hop is step 6: a trigger firing does **not**
  guarantee a turn. RateLimit sits between "this bot wants to speak"
  and "this bot speaks", and a suppression is a first-class logged
  outcome — not an error.

  ## Sister apps and shared primitives

  Bots are not special. They read through
  `Commonplace.Tree.DocBuilder` and write through
  `Commonplace.Chat.Actions` / `Commonplace.Chat.Messages` — the
  same paths the web UI and any future MCP server use. Presence
  flicker goes through `Commonplace.Presence`; the per-bot durable
  trail uses `Commonplace.Dataflow.RedLog`. The dispatcher is
  umbrella infra alongside `Commonplace.Sync.Agent`, not an
  orchestrator-compiled `.exs` process.

  The authoritative spec is the modules themselves: this overview,
  `Commonplace.Bots.Entity` (the doc-tree contract), and
  `Commonplace.Bots.Worker` (the cave-diver caps and outcomes) —
  there is no separate design doc to keep in sync.
  """
end
