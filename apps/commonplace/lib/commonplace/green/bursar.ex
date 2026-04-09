defmodule Commonplace.Green.Bursar do
  @moduledoc """
  Green Token bursar — exclusive lock manager for commonplace documents.

  Manages named tokens (path-based, same namespace as documents) with
  deny-on-contention semantics: if a token is held, new requests are rejected.

  ## State Storage

  - `__bursar.json` — YMap (blue state): current token holders
  - `__bursar.log` — JSONL (red events): audit log of all acquire/release/deny events

  The bursar is the only writer to `__bursar.json`. Everyone else reads.

  ## API Layers

  - **GenServer.call** — same-node callers (Orchestrator, sync agents)
  - **Magenta PubSub** — graph-internal processes send commands via magenta topics
  - **CommitStoreClient** — remote callers via distributed Erlang

  ## Token Format

  Tokens are named by path (e.g., "readme.txt", "docs/guide.md").
  Holders are identified by a string (process name, session ID, etc.).
  """

  use GenServer
  require Logger

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
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

    sweep_interval = Keyword.get(opts, :sweep_interval, 10_000)
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

        new_info = %{info | acquired_at: DateTime.utc_now(), ttl_ms: ttl_ms}
        tokens = Map.put(state.tokens, path, new_info)
        state = %{state | tokens: tokens}
        state = persist_state(state)
        extra = if ttl_ms, do: %{"ttl_ms" => ttl_ms}, else: %{}
        state = log_event(state, "renew", path, holder, extra)

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
          ttl_ms = new_ttl_ms || info.ttl_ms
          new_info = %{info | acquired_at: DateTime.utc_now(), ttl_ms: ttl_ms}
          tokens = Map.put(state.tokens, path, new_info)
          state = %{state | tokens: tokens}
          state = persist_state(state)
          extra = if ttl_ms, do: %{"ttl_ms" => ttl_ms, "via" => "magenta"}, else: %{"via" => "magenta"}
          state = log_event(state, "renew", path, holder, extra)
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
                  tokens = Map.new(map, fn {path, info} ->
                    acquired_at = case DateTime.from_iso8601(info["acquired_at"] || "") do
                      {:ok, dt, _} -> dt
                      _ -> DateTime.utc_now()
                    end
                    ttl_ms = info["ttl_ms"]
                    {path, %{holder: info["holder"], acquired_at: acquired_at, ttl_ms: ttl_ms}}
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

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, @state_doc)
    doc = ContentType.insert_text(doc, 0, Jason.encode!(json, pretty: true))
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
    doc = Yelixer.Doc.new()
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
end
