defmodule Commonplace.Bots.Worker do
  @moduledoc """
  Ephemeral cave-diver worker — one turn per bot per fired trigger.

  A worker is a **Task** supervised by
  `Commonplace.Bots.WorkerSupervisor`. It is born when the
  dispatcher's worker_hook fires; it runs an Anthropic Messages
  API tool-use loop with hard caps on calls, output tokens, and
  wall-clock; it exits when the model says it's done, when a
  cap is hit, or when it errors out. There is no compaction;
  there is no persistent worker state. Memory between turns
  lives in the substrate (the bot's `memory.jsonl` doc), not in
  process state.

  ## Hard caps (defaults; per-bot overrides via `bot.json`)

      max_calls        — 10
      max_output_tokens — 4096
      max_wall_ms       — 60_000

  When a cap is hit, the worker terminates with a
  `{:cap_hit, which}` outcome — no apology message is posted
  to the chat. Failure visibility is via the entity's red log
  and the room's `__bot_activity` doc (phase 6).

  ## Substrate-pure I/O

  Tools route through the same primitives any other client uses:

    * `post_message` calls `Commonplace.Chat.Actions.post_message/3`
      with the bot's `author_path` (e.g. `"alice.bot"`).
    * `remember` appends a JSON line to the bot's `memory.jsonl`
      via the same Yjs text-append primitive any other client
      would use.
    * `read_chat`, `read_memory`, `list_files`, `read_file` (phase 5)
      read through `DocBuilder.reconstruct_snapshot/2` — the same
      read path used by the web UI and any future MCP server.

  The principle: a human UI and an MCP server are peers; the
  worker is *also* a peer. No bot-only fast lanes.

  ## Dependency injection

  Two hooks for tests:

    * `:client_fn` — `(request_map -> {:ok, response} | {:error, term})`.
      Default is `Commonplace.Bots.Worker.Client.call/1`. Tests pass a
      stub that returns deterministic Messages-API-shaped responses
      so the loop's tool-dispatch and cap-enforcement mechanics are
      testable without an API key.
    * `:tools_module` — defaults to `Commonplace.Bots.Worker.Tools`.
      Tests can swap in a stub that records dispatched tool calls.

  ## Lifecycle

      Worker.spawn(room, entity, event, opts \\\\ [])
        # → starts a supervised Task; returns {:ok, pid}.

  The Task body calls `run/4`, which drives the loop and emits a
  final telemetry event for outcome inspection.
  """

  alias Commonplace.Bots.Entity
  alias Commonplace.Bots.Worker.{Client, Loop, Tools}

  @type outcome ::
          {:ok, :end_turn}
          | {:cap_hit, :calls | :output_tokens | :wall_clock | :max_tokens}
          | {:error, term()}

  @default_max_calls 10
  @default_max_output_tokens 4_096
  @default_max_wall_ms 60_000

  @spec spawn(String.t(), Entity.t(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn(room, %Entity{} = entity, event, opts \\ []) do
    Task.Supervisor.start_child(
      Commonplace.Bots.WorkerSupervisor,
      __MODULE__,
      :run,
      [room, entity, event, opts]
    )
  end

  @doc """
  Entry point for the supervised worker task. Drives the
  tool-use loop until it terminates and emits the outcome
  telemetry. Returns the outcome so test code that bypasses
  Task.Supervisor can call `run/4` directly and assert on it.
  """
  @spec run(String.t(), Entity.t(), map(), keyword()) :: outcome()
  def run(room, %Entity{} = entity, event, opts \\ []) do
    config = build_config(entity, opts)
    client_fn = Keyword.get(opts, :client_fn, &Client.call/1)
    tools_module = Keyword.get(opts, :tools_module, Tools)

    :telemetry.execute(
      [:commonplace, :bots, :worker, :started],
      %{system_time: System.system_time()},
      %{room: room, bot: entity.name, message_id: Map.get(event, "message_id")}
    )

    outcome =
      Loop.run(%{
        room: room,
        entity: entity,
        event: event,
        config: config,
        client_fn: client_fn,
        tools_module: tools_module,
        opts: opts
      })

    :telemetry.execute(
      [:commonplace, :bots, :worker, :finished],
      %{system_time: System.system_time()},
      %{room: room, bot: entity.name, outcome: outcome}
    )

    outcome
  end

  @default_fallback_model "claude-haiku-4-5-20251001"

  defp build_config(%Entity{bot_config: bot_config}, opts) do
    %{
      max_calls: fetch_pos_int(bot_config, "max_calls", opts, :max_calls, @default_max_calls),
      max_output_tokens:
        fetch_pos_int(
          bot_config,
          "max_output_tokens",
          opts,
          :max_output_tokens,
          @default_max_output_tokens
        ),
      max_wall_ms:
        fetch_pos_int(bot_config, "max_wall_ms", opts, :max_wall_ms, @default_max_wall_ms),
      model: Keyword.get(opts, :model, Map.get(bot_config, "model", "claude-sonnet-4-6")),
      fallback_model:
        Keyword.get(
          opts,
          :fallback_model,
          Map.get(bot_config, "fallback_model", @default_fallback_model)
        )
    }
  end

  defp fetch_pos_int(bot_config, key, opts, opt_key, default) do
    cond do
      v = Keyword.get(opts, opt_key) -> v
      is_integer(bot_config[key]) and bot_config[key] > 0 -> bot_config[key]
      true -> default
    end
  end
end
