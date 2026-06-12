defmodule Commonplace.Green.Bursar do
  @moduledoc """
  Green-channel **exclusive-lock manager** for commonplace documents.

  The bursar hands out at most one *token* per path. Tokens are named by
  path (same namespace as documents — e.g. `"readme.txt"`,
  `"docs/guide.md"`) and a *holder* is any string the caller picks
  (process name, session id, …). Contention is resolved by
  **deny-on-contention, not queueing**: if a token is already held, a
  competing `acquire` is rejected immediately (`{:denied, holder_info}`)
  rather than blocked — a caller who wants the lock retries. Re-acquiring
  a token you already hold is an idempotent success. Denying rather than
  queueing keeps the bursar from having to hold a waiter list and reason
  about waiters' liveness (a waiter that crashed mid-queue, ordering
  across nodes); retry policy lives with the caller instead.

  ## Token lifecycle

  Beyond acquire/release the bursar manages the full custody lifecycle:

    * `acquire/4` — grab a free token; optional `ttl:` makes it
      auto-expire.
    * `release/3` — drop a token you hold (holder-checked).
    * `transfer/4` — hand a held token to a new holder; the clock
      (`acquired_at` + remaining `ttl_ms`) is **inherited, not reset**.
    * `renew/4` — keep-alive: re-clock `acquired_at` (optionally changing
      the TTL) so a long-running hold doesn't expire under the sweep.
    * `query/2` / `list_tokens/1` — read current custody.
    * `force_release/2` — admin break-glass; drops a token regardless of
      holder.

  **TTL auto-expiry.** A token acquired with `ttl:` is released without a
  caller: a periodic sweep (`:sweep_ttl`, every `sweep_interval` ms)
  drops any token whose `acquired_at + ttl_ms` has elapsed and emits a
  `released` event with `reason: "expired"`. TTL is the safety net
  against a holder that crashes without releasing.

  **Ephemeral liveness vs durable ownership (move #4, CX-tdkq.7).**
  Ownership changes — acquire / release / transfer / expiry — are
  persisted and logged. `renew` is **memory-only**: it re-clocks
  `acquired_at` in the token table and broadcasts, but never commits
  (a lease heartbeat at TTL/3 would otherwise write ~17k commits/day
  into an append-only store). The restart story compensates:
  `load_state` **re-clocks every loaded token to load time**, granting
  a full fresh TTL. The load-bearing safety invariant is that re-clock
  can only EXTEND a lease, never release it early — combined with
  deny-on-contention this means a Bursar restart can delay failover by
  at most one extra TTL but can never produce two concurrent holders.
  (Corollary: a `renew ttl:`-changed TTL is not durable across a
  restart; the acquire-time TTL is what reloads.)

  ## State & audit (blue + red)

  Two documents under the bursar's root, both written *only* by the
  bursar (everyone else reads):

    * `__bursar.json` — the live holder table, a JSON blob in a CRDT
      text doc (**blue** state). Reconstructed on start, so custody
      survives a bursar restart.
    * `__bursar.log` — an append-only JSONL audit of every
      acquire / release / deny / transfer / renew / expire (**red**
      events).

  (See `Commonplace.Dataflow.Channel` for the blue/red distinction.)
  Writes to `__bursar.json` use the stable-client_id + incremental-diff
  pattern (CX-pyi) so the Yjs state vector stays bounded across many
  custody changes.

  ## Command transports

  The same operations are reachable two ways:

    * **`GenServer.call`** — the typed `acquire`/`release`/… functions
      above, for same-node callers (Orchestrator, sync agents).
    * **Magenta commands** — graph-internal / cross-process callers send
      `green:acquire` / `green:release` / `green:transfer` / `green:renew`
      / `green:query` messages on the `"__bursar"` magenta topic; the
      bursar announces outcomes by broadcasting `green:*` event messages
      back on that same topic.

  Note the transport nuance: although exclusive locking is the **green**
  concern in the channel taxonomy, the bursar currently carries its
  commands and events over a dedicated *magenta* topic with `green:`
  message-type prefixes — it does **not** use the `green:{uuid}` PubSub
  topic (those helpers exist but are unused here). There is no separate
  "remote caller" API: a remote observer simply reads `__bursar.json` /
  `__bursar.log` through the store.
  """

  use GenServer
  require Logger

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.{ContentType, Diff}
  alias Commonplace.Dataflow.{Magenta, RedLog}

  @state_doc "__bursar.json"
  @log_doc "__bursar.log"
  @magenta_topic "__bursar"

  defstruct [
    :root_uuid,
    :store,
    :state_uuid,
    :log_uuid,
    :log,
    tokens: %{},  # %{path => %{holder: string, acquired_at: DateTime, ttl_ms: integer | nil}}
    sweep_interval: 10_000  # ms between TTL sweep checks
  ]

  # --- Client API ---

  @doc "Start the bursar GenServer."
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquire an exclusive token for a path.
  Options: [ttl: milliseconds] — auto-expires after TTL. Default: no expiry.
  Returns {:ok, token_info} or {:denied, holder_info}.
  """
  def acquire(server \\ __MODULE__, path, holder, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl, nil)
    GenServer.call(server, {:acquire, path, holder, ttl_ms})
  end

  @doc """
  Release a held token. Only the current holder can release.
  Returns :ok or {:error, reason}.
  """
  def release(server \\ __MODULE__, path, holder) do
    GenServer.call(server, {:release, path, holder})
  end

  @doc """
  Query token status for a path.
  Returns {:held, holder_info} or :available.
  """
  def query(server \\ __MODULE__, path) do
    GenServer.call(server, {:query, path})
  end

  @doc "List all currently held tokens."
  def list_tokens(server \\ __MODULE__) do
    GenServer.call(server, :list_tokens)
  end

  @doc "Force-release a token (admin operation)."
  def force_release(server \\ __MODULE__, path) do
    GenServer.call(server, {:force_release, path})
  end

  @doc """
  Transfer an exclusive token from `from_holder` to `to_holder`.
  Only the current holder can transfer. `acquired_at` and `ttl_ms` are preserved
  (i.e. the new holder inherits the remaining time on the clock).
  Returns {:ok, token_info} or {:error, reason}.
  """
  def transfer(server \\ __MODULE__, path, from_holder, to_holder) do
    GenServer.call(server, {:transfer, path, from_holder, to_holder})
  end

  @doc """
  Renew (keep-alive) a held token. Resets `acquired_at` to now, re-clocking the
  TTL sweep. Options: [ttl: milliseconds] — if provided, updates the TTL value;
  otherwise keeps the existing TTL.
  Returns {:ok, token_info} or {:error, reason}.
  """
  def renew(server \\ __MODULE__, path, holder, opts \\ []) do
    new_ttl_ms =
      case Keyword.fetch(opts, :ttl) do
        {:ok, v} -> {:set, v}
        :error -> :keep
      end

    GenServer.call(server, {:renew, path, holder, new_ttl_ms})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.get(opts, :store, CommitStoreClient)

    # Subscribe to magenta commands
    Magenta.subscribe(@magenta_topic)

    # Load or create state
    state = %__MODULE__{root_uuid: root_uuid, store: store}
    state = load_state(state)

    # Expiry detection lags a dead lease by up to one sweep; embedders
    # that need faster failover configure :bursar_sweep_interval_ms.
    sweep_interval =
      Keyword.get(opts, :sweep_interval) ||
        Application.get_env(:commonplace, :bursar_sweep_interval_ms, 10_000)

    state = %{state | sweep_interval: sweep_interval}

    # Start TTL sweep timer
    Process.send_after(self(), :sweep_ttl, sweep_interval)

    Logger.info("Bursar started for #{root_uuid}, #{map_size(state.tokens)} active tokens")
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, path, holder, ttl_ms}, _from, state) do
    case Map.get(state.tokens, path) do
      nil ->
        # Token available — grant it
        token_info = %{holder: holder, acquired_at: DateTime.utc_now(), ttl_ms: ttl_ms}
        tokens = Map.put(state.tokens, path, token_info)
        state = %{state | tokens: tokens}
        state = persist_state(state)
        ttl_extra = if ttl_ms, do: %{ttl_ms: ttl_ms}, else: %{}
        state = log_event(state, "acquire", path, holder, ttl_extra)

        broadcast_green_event("acquired", path, holder)
        {:reply, {:ok, token_info}, state}

      %{holder: ^holder} = existing ->
        # Same holder already has it — idempotent success
        {:reply, {:ok, existing}, state}

      %{holder: current_holder} ->
        # Held by someone else — deny
        state = log_event(state, "denied", path, holder, %{current_holder: current_holder})
        {:reply, {:denied, %{holder: current_holder}}, state}
    end
  end

  # Legacy arity-3 acquire (without TTL) — dispatch to arity-4
  @impl true
  def handle_call({:acquire, path, holder}, from, state) do
    handle_call({:acquire, path, holder, nil}, from, state)
  end

  @impl true
  def handle_call({:release, path, holder}, _from, state) do
    case Map.get(state.tokens, path) do
      %{holder: ^holder} ->
        tokens = Map.delete(state.tokens, path)
        state = %{state | tokens: tokens}
        state = persist_state(state)
        state = log_event(state, "release", path, holder)

        broadcast_green_event("released", path, holder)
        {:reply, :ok, state}

      %{holder: other} ->
        {:reply, {:error, {:not_holder, other}}, state}

      nil ->
        {:reply, {:error, :not_held}, state}
    end
  end

  @impl true
  def handle_call({:query, path}, _from, state) do
    case Map.get(state.tokens, path) do
      nil -> {:reply, :available, state}
      info -> {:reply, {:held, info}, state}
    end
  end

  @impl true
  def handle_call(:list_tokens, _from, state) do
    {:reply, state.tokens, state}
  end

  @impl true
  def handle_call({:transfer, path, from_holder, to_holder}, _from, state) do
    case Map.get(state.tokens, path) do
      nil ->
        {:reply, {:error, :not_held}, state}

      %{holder: ^from_holder} = info ->
        new_info = %{info | holder: to_holder}
        tokens = Map.put(state.tokens, path, new_info)
        state = %{state | tokens: tokens}
        state = persist_state(state)
        state = log_event(state, "transfer", path, to_holder, %{"from" => from_holder, "to" => to_holder})

        broadcast_green_event("transferred", path, to_holder, %{"from" => from_holder})
        {:reply, {:ok, new_info}, state}

      %{holder: current_holder} ->
        {:reply, {:error, {:not_holder, current_holder}}, state}
    end
  end

  @impl true
  def handle_call({:renew, path, holder, new_ttl}, _from, state) do
    case Map.get(state.tokens, path) do
      nil ->
        {:reply, {:error, :not_held}, state}

      %{holder: ^holder} = info ->
        ttl_ms =
          case new_ttl do
            {:set, v} -> v
            :keep -> info.ttl_ms
          end

        # Liveness is EPHEMERAL (move #4): renew updates memory only — no
        # persist_state, no log_event. A heartbeat renewing every TTL/3
        # would otherwise commit ~17k times/day into an append-only store.
        # Restart durability comes from load_state's re-clock instead.
        new_info = %{info | acquired_at: DateTime.utc_now(), ttl_ms: ttl_ms}
        tokens = Map.put(state.tokens, path, new_info)
        state = %{state | tokens: tokens}
        extra = if ttl_ms, do: %{"ttl_ms" => ttl_ms}, else: %{}

        broadcast_green_event("renewed", path, holder, extra)
        {:reply, {:ok, new_info}, state}

      %{holder: current_holder} ->
        {:reply, {:error, {:not_holder, current_holder}}, state}
    end
  end

  @impl true
  def handle_call({:force_release, path}, _from, state) do
    case Map.get(state.tokens, path) do
      %{holder: old_holder} ->
        tokens = Map.delete(state.tokens, path)
        state = %{state | tokens: tokens}
        state = persist_state(state)
        state = log_event(state, "force_release", path, "admin", %{previous_holder: old_holder})

        broadcast_green_event("released", path, old_holder)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_held}, state}
    end
  end

  # --- Magenta Command Handler ---

  @impl true
  def handle_info({:magenta, _topic, %Magenta{type: "green:acquire"} = msg}, state) do
    path = msg.payload["path"]
    holder = msg.payload["holder"] || msg.source
    ttl_ms = msg.payload["ttl_ms"]

    if path do
      case Map.get(state.tokens, path) do
        nil ->
          token_info = %{holder: holder, acquired_at: DateTime.utc_now(), ttl_ms: ttl_ms}
          tokens = Map.put(state.tokens, path, token_info)
          state = %{state | tokens: tokens}
          state = persist_state(state)
          ttl_extra = if ttl_ms, do: %{ttl_ms: ttl_ms}, else: %{}
          state = log_event(state, "acquire", path, holder, Map.merge(%{via: "magenta"}, ttl_extra))
          broadcast_green_event("acquired", path, holder)
          {:noreply, state}

        %{holder: ^holder} ->
          # Already held by requester — no-op
          {:noreply, state}

        %{holder: current_holder} ->
          state = log_event(state, "denied", path, holder, %{current_holder: current_holder, via: "magenta"})
          broadcast_green_event("denied", path, holder, %{current_holder: current_holder})
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:magenta, _topic, %Magenta{type: "green:release"} = msg}, state) do
    path = msg.payload["path"]
    holder = msg.payload["holder"] || msg.source

    if path do
      case Map.get(state.tokens, path) do
        %{holder: ^holder} ->
          tokens = Map.delete(state.tokens, path)
          state = %{state | tokens: tokens}
          state = persist_state(state)
          state = log_event(state, "release", path, holder, %{via: "magenta"})
          broadcast_green_event("released", path, holder)
          {:noreply, state}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:magenta, _topic, %Magenta{type: "green:transfer"} = msg}, state) do
    path = msg.payload["path"]
    from_holder = msg.payload["from"] || msg.source
    to_holder = msg.payload["to"]

    cond do
      is_nil(path) or is_nil(to_holder) ->
        {:noreply, state}

      true ->
        case Map.get(state.tokens, path) do
          nil ->
            {:noreply, state}

          %{holder: ^from_holder} = info ->
            new_info = %{info | holder: to_holder}
            tokens = Map.put(state.tokens, path, new_info)
            state = %{state | tokens: tokens}
            state = persist_state(state)
            state =
              log_event(state, "transfer", path, to_holder, %{
                "from" => from_holder,
                "to" => to_holder,
                "via" => "magenta"
              })
            broadcast_green_event("transferred", path, to_holder, %{"from" => from_holder})
            {:noreply, state}

          %{holder: current_holder} ->
            state =
              log_event(state, "denied", path, from_holder, %{
                current_holder: current_holder,
                via: "magenta",
                op: "transfer"
              })
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:magenta, _topic, %Magenta{type: "green:renew"} = msg}, state) do
    path = msg.payload["path"]
    holder = msg.payload["holder"] || msg.source
    new_ttl_ms = msg.payload["ttl_ms"]

    if path do
      case Map.get(state.tokens, path) do
        nil ->
          {:noreply, state}

        %{holder: ^holder} = info ->
          # Memory-only, same as the call path — see handle_call({:renew,...}).
          ttl_ms = new_ttl_ms || info.ttl_ms
          new_info = %{info | acquired_at: DateTime.utc_now(), ttl_ms: ttl_ms}
          tokens = Map.put(state.tokens, path, new_info)
          state = %{state | tokens: tokens}
          broadcast_green_event("renewed", path, holder, %{"ttl_ms" => ttl_ms})
          {:noreply, state}

        %{holder: current_holder} ->
          state =
            log_event(state, "denied", path, holder, %{
              current_holder: current_holder,
              via: "magenta",
              op: "renew"
            })
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:magenta, _topic, %Magenta{type: "green:query"} = msg}, state) do
    path = msg.payload["path"]
    reply_to = msg.source

    if path do
      status = case Map.get(state.tokens, path) do
        nil -> %{status: "available", path: path}
        %{holder: h, acquired_at: at} -> %{status: "held", path: path, holder: h, acquired_at: DateTime.to_iso8601(at)}
      end

      Magenta.send(@magenta_topic, Magenta.message("green:status", "bursar", Map.put(status, "reply_to", reply_to)))
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep_ttl, state) do
    now = DateTime.utc_now()

    expired =
      Enum.filter(state.tokens, fn {_path, info} ->
        case info.ttl_ms do
          nil -> false
          ttl ->
            elapsed = DateTime.diff(now, info.acquired_at, :millisecond)
            elapsed >= ttl
        end
      end)

    state =
      Enum.reduce(expired, state, fn {path, info}, acc ->
        tokens = Map.delete(acc.tokens, path)
        acc = %{acc | tokens: tokens}
        acc = persist_state(acc)
        acc = log_event(acc, "expired", path, info.holder, %{ttl_ms: info.ttl_ms})
        broadcast_green_event("released", path, info.holder, %{reason: "expired"})
        Logger.info("Bursar: token expired — #{path} (held by #{info.holder})")
        acc
      end)

    # Schedule next sweep
    Process.send_after(self(), :sweep_ttl, state.sweep_interval)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- State Persistence ---

  defp load_state(state) do
    schema = load_root_schema(state)

    # Load or create state document
    {state_uuid, tokens} =
      case Schema.get_entry(schema, @state_doc) do
        {:ok, entry} ->
          case DocBuilder.reconstruct_snapshot(state.store, entry.node_id) do
            {:ok, doc} ->
              json_str = ContentType.get_content(doc) || "{}"
              case Jason.decode(json_str) do
                {:ok, map} when is_map(map) ->
                  # RE-CLOCK on load (move #4): renews are memory-only, so a
                  # stored acquired_at understates liveness. Every loaded token
                  # gets a fresh full TTL from load time. INVARIANT: re-clock
                  # can only EXTEND a lease, never release it early — acquire
                  # denies while any unexpired token exists, so the worst case
                  # of a dead holder's lingering lease is failover LATENCY
                  # (≤ one extra TTL after a restart), never two holders. The
                  # stored acquired_at remains in __bursar.json for audit only.
                  now = DateTime.utc_now()

                  tokens = Map.new(map, fn {path, info} ->
                    {path, %{holder: info["holder"], acquired_at: now, ttl_ms: info["ttl_ms"]}}
                  end)

                  {entry.node_id, tokens}
                _ ->
                  {entry.node_id, %{}}
              end
            :none ->
              {entry.node_id, %{}}
          end
        :error ->
          uuid = create_state_doc(state, schema)
          {uuid, %{}}
      end

    # Load or create log document
    log_uuid =
      case Schema.get_entry(schema, @log_doc) do
        {:ok, entry} -> entry.node_id
        :error -> create_log_doc(state, schema)
      end

    log = RedLog.load(log_uuid, state.store)

    %{state | state_uuid: state_uuid, log_uuid: log_uuid, log: log, tokens: tokens}
  end

  defp persist_state(state) do
    # Serialize tokens to JSON
    json = Map.new(state.tokens, fn {path, %{holder: holder, acquired_at: at} = info} ->
      entry = %{"holder" => holder, "acquired_at" => DateTime.to_iso8601(at)}
      entry = if info[:ttl_ms], do: Map.put(entry, "ttl_ms", info.ttl_ms), else: entry
      {path, entry}
    end)

    new_content = Jason.encode!(json, pretty: true)

    # CX-pyi: load + mutate. Reconstruct existing state under a stable
    # client_id and apply the JSON-content diff incrementally so the
    # SV stays at one slot across many persist_state calls.
    doc =
      case CommitStoreClient.latest_commit(state.store, state.state_uuid) do
        {:ok, commit} ->
          d = Yelixer.Doc.new(client_id: stable_client_id(state.state_uuid))
          {:ok, d} = Yelixer.Encoding.apply_update(d, commit.update)
          d

        :none ->
          d = Yelixer.Doc.new(client_id: stable_client_id(state.state_uuid))
          ContentType.create(d, :text, @state_doc)
      end

    old_content = ContentType.get_content(doc) || ""
    doc = Diff.apply_diff(doc, old_content, new_content)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(state.store, state.state_uuid, update)

    state
  end

  defp log_event(state, event_type, path, holder, extra \\ %{}) do
    event = Map.merge(extra, %{
      "event" => event_type,
      "path" => path,
      "holder" => holder,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })

    log = RedLog.append_raw(state.log, event)
    log = RedLog.commit(log)
    %{state | log: log}
  end

  defp broadcast_green_event(event_type, path, holder, extra \\ %{}) do
    payload = Map.merge(extra, %{"path" => path, "holder" => holder})
    Magenta.send(@magenta_topic, Magenta.message("green:#{event_type}", "bursar", payload))
  end

  # --- Schema Helpers ---

  defp load_root_schema(state) do
    case DocBuilder.reconstruct_snapshot(state.store, state.root_uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp create_state_doc(state, schema) do
    uuid = UUID.uuid4()
    # CX-pyi: stable client_id so subsequent persist_state writes share
    # this SV slot (without it, even the first persist would diverge).
    doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
    doc = ContentType.create(doc, :text, @state_doc)
    doc = ContentType.insert_text(doc, 0, "{}")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_commit(state.store, uuid, update, nil)

    # Add to schema
    schema = Schema.add_file(schema, @state_doc, uuid)
    schema_update = Yelixer.Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(state.store, state.root_uuid, schema_update)

    uuid
  end

  defp create_log_doc(state, _schema) do
    uuid = UUID.uuid4()
    log = RedLog.new(uuid, state.store)
    RedLog.commit(log)

    # Reload schema (may have been updated by create_state_doc)
    schema = load_root_schema(state)
    schema = Schema.add_file(schema, @log_doc, uuid)
    schema_update = Yelixer.Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(state.store, state.root_uuid, schema_update)

    uuid
  end

  # CX-pyi: stable client_id keeps the SV at one slot per state doc
  # across many persist_state calls.
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end
end
