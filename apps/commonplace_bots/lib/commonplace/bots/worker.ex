defmodule Commonplace.Bots.Worker do
  @moduledoc """
  Ephemeral "cave-diver" worker — one turn per bot per fired trigger.
  The metaphor names the lifecycle: it dives in on a fixed air supply
  (the hard caps below), does one turn's work, and surfaces carrying
  nothing — every durable result was written to the substrate, never
  held in process state.

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
  to the chat. Failure (and success) visibility is via the two
  durable trails described under "Observable side effects" below.

  ## Substrate-pure I/O

  Tools route through the same primitives any other client uses:

    * `post_message` calls `Commonplace.Chat.Actions.post_message/3`
      with the bot's `author_path` (e.g. `"alice.bot"`).
    * `remember` appends a JSON line to the bot's `memory.jsonl`
      via the same Yjs text-append primitive any other client
      would use.
    * `read_chat`, `read_memory`, `list_files`, `read_file` read
      through `DocBuilder.reconstruct_snapshot/2` — the same
      read path used by the web UI and any future MCP server.

  The principle: a human UI and an MCP server are peers; the
  worker is *also* a peer. No bot-only fast lanes.

  ## Observable side effects

  Beyond posting and remembering through the substrate, a running
  worker leaves three observable traces — all best-effort (a failed
  write emits telemetry but never takes the worker down; observability
  must not gate behavior):

    * **`.exe` presence flicker** (CX-q8nk(1)). For the duration of
      the loop the worker registers a transient honorific
      `<name>-<short_id>.exe` doc under the bot's directory, and always
      removes it on exit — success, cap, error, or crash. `.exe` is the
      tree's "live process / running presence" actor tag (see the
      honorific legend in `Commonplace.Bots`), so the presence doc makes
      a worker's run visible *in the tree itself*, not just in logs.

    * **Per-bot red log** (CX-q8nk(2)). On exit the outcome is appended
      to the bot's own `__red_log` doc (via `Commonplace.Dataflow.RedLog`)
      when one exists: the bot's *private, durable* trail of every turn
      it has taken, across every room it operates in.

    * **Room activity log** (CX-gptu). The terminal
      `[:commonplace, :bots, :worker, :finished]` telemetry event is
      what the dispatcher fans out into the room's `__bot_activity` doc
      — the *room's* view of every bot that fired in it.

  The two durable logs are complementary axes, deliberately not merged:
  `__red_log` answers "what has this one bot done, everywhere?";
  `__bot_activity` answers "what happened in this room?".

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
    signing_context = resolve_signing_context(entity, opts)

    :telemetry.execute(
      [:commonplace, :bots, :worker, :started],
      %{system_time: System.system_time()},
      %{room: room, bot: entity.name, message_id: Map.get(event, "message_id")}
    )

    # CX-q8nk(1): .exe presence flicker. Register a per-worker
    # honorific .exe under the bot's directory while the loop runs;
    # always remove it on exit (success, cap, error, crash). Skip
    # cleanly if Presence.create fails so a flaky write doesn't
    # take the worker down — observability shouldn't gate behavior.
    presence = maybe_start_presence(entity, opts)

    outcome =
      try do
        Loop.run(%{
          room: room,
          entity: entity,
          event: event,
          config: config,
          client_fn: client_fn,
          tools_module: tools_module,
          signing_context: signing_context,
          opts: opts
        })
      after
        maybe_stop_presence(presence)
      end

    :telemetry.execute(
      [:commonplace, :bots, :worker, :finished],
      %{system_time: System.system_time()},
      %{room: room, bot: entity.name, outcome: outcome}
    )

    # CX-q8nk(2): per-entity red log — append the outcome event to
    # the bot's own __red_log doc when one exists. Distinct from
    # the room-level __bot_activity log (CX-gptu): __red_log is
    # the bot's private durable trail across rooms; __bot_activity
    # is the room's view of all bots that fired in it. A bot that
    # operates in multiple rooms gets one cross-room ledger here.
    maybe_write_red_log(entity, room, event, outcome, opts)

    outcome
  end

  # Returns either a {fname, dir_uuid, store} tuple to clean up on
  # exit, or nil when presence is disabled / minting failed.
  defp maybe_start_presence(%Entity{} = entity, opts) do
    if Keyword.get(opts, :presence_enabled, true) do
      worker_name = "#{entity.name}-#{short_id()}"
      fname = "#{worker_name}.exe"
      store = Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient)

      try do
        case Commonplace.Presence.create(worker_name, :exe, entity.dir_uuid, store) do
          {:ok, _uuid} ->
            :telemetry.execute(
              [:commonplace, :bots, :worker, :presence_started],
              %{system_time: System.system_time()},
              %{bot: entity.name, fname: fname, dir_uuid: entity.dir_uuid}
            )

            {fname, entity.dir_uuid, store}

          _ ->
            nil
        end
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    else
      nil
    end
  end

  defp maybe_stop_presence(nil), do: :ok

  defp maybe_stop_presence({fname, dir_uuid, store}) do
    try do
      Commonplace.Presence.remove(fname, dir_uuid, store)

      :telemetry.execute(
        [:commonplace, :bots, :worker, :presence_stopped],
        %{system_time: System.system_time()},
        %{fname: fname, dir_uuid: dir_uuid}
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp short_id, do: UUID.uuid4() |> String.slice(0..7)

  @red_log_child "__red_log"

  defp maybe_write_red_log(%Entity{children: children} = entity, room, event, outcome, opts) do
    case Map.get(children, @red_log_child) do
      nil ->
        :ok

      red_log_uuid when is_binary(red_log_uuid) ->
        store = Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient)
        entry = outcome_to_event(room, entity, event, outcome)

        try do
          Commonplace.Dataflow.RedLog.load(red_log_uuid, store)
          |> Commonplace.Dataflow.RedLog.append_raw(entry)
          |> Commonplace.Dataflow.RedLog.commit()

          :telemetry.execute(
            [:commonplace, :bots, :worker, :red_log_written],
            %{system_time: System.system_time()},
            %{bot: entity.name, room: room, red_log_uuid: red_log_uuid}
          )
        rescue
          e ->
            :telemetry.execute(
              [:commonplace, :bots, :worker, :red_log_write_failed],
              %{system_time: System.system_time()},
              %{bot: entity.name, reason: Exception.message(e)}
            )
        catch
          kind, reason ->
            :telemetry.execute(
              [:commonplace, :bots, :worker, :red_log_write_failed],
              %{system_time: System.system_time()},
              %{bot: entity.name, reason: "#{kind}: #{inspect(reason)}"}
            )
        end
    end
  end

  defp outcome_to_event(room, %Entity{} = entity, event, outcome) do
    base = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "worker_outcome",
      "room" => room,
      "bot" => entity.name,
      "message_id" => Map.get(event, "message_id"),
      "source_author" => Map.get(event, "author_path")
    }

    Map.merge(base, outcome_fields(outcome))
  end

  defp outcome_fields({:ok, :end_turn}), do: %{"decision" => "completed"}

  defp outcome_fields({:cap_hit, which}),
    do: %{"decision" => "cap_hit", "reason" => to_string(which)}

  defp outcome_fields({:error, reason}),
    do: %{"decision" => "error", "reason" => inspect(reason)}

  defp outcome_fields(other),
    do: %{"decision" => "error", "reason" => "unexpected: #{inspect(other)}"}

  # Camillo C1: resolve the bot's OWN Ed25519 signing context once per run
  # and thread it into the loop so tool writes (`post_message`, `remember`)
  # are genuinely signed by the bot's key. Degrades gracefully — a nil
  # context means unsigned writes (denied under enforce, an honest failure),
  # never a crash.
  #
  # SECURITY: only what the runtime legitimately needs is forwarded to
  # `Commonplace.Bots.Identity.resolve_signing_context/4` — root_uuid, store,
  # secret_store. The raw worker `opts` are NOT passed through, so a
  # caller-supplied `:registrar_signing_context` in the spawn opts can NEVER
  # steer WHO attests the identity's registration; on this runtime path the
  # registrar always defaults to the node context. See
  # `Commonplace.Bots.Identity`'s security contract.
  defp resolve_signing_context(%Entity{} = entity, opts) do
    root = Keyword.get(opts, :root_uuid) || workspace_root()
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient)

    if is_binary(root) do
      secret_store = Keyword.get(opts, :secret_store, Commonplace.Store.SecretStore)

      case Commonplace.Bots.Identity.resolve_signing_context(entity.name, root, store,
             secret_store: secret_store
           ) do
        {:ok, sc} ->
          sc

        {:error, reason} ->
          :telemetry.execute(
            [:commonplace, :bots, :worker, :signing_unresolved],
            %{system_time: System.system_time()},
            %{bot: entity.name, reason: inspect(reason)}
          )

          nil
      end
    else
      nil
    end
  end

  defp workspace_root do
    case Commonplace.Workspace.root_uuid() do
      {:ok, r} -> r
      _ -> nil
    end
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
