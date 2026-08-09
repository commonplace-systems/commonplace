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

  **Ephemeral liveness vs durable ownership (move #4, CX-tdkq.7;
  CX-i9ca).** Only **permanent** (`ttl_ms == nil`) tokens are persisted
  to `__bursar.json` — these are the durable OWNERSHIP tokens that must
  survive a restart. **Ephemeral** (`ttl`'d) tokens — move-locks, the
  tick-lease, craft-locks — are memory-only transient coordination:
  losing them on a crash is correct (no in-flight move survives, the
  lease is re-elected), and persisting them churned the doc until
  `persist_state` wedged the serve (CX-i9ca). Every ownership change to a
  permanent token (acquire / release / transfer) is persisted and logged;
  the same op on a ttl'd token is logged but not committed. `renew` is
  **memory-only**: it re-clocks
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
      events). Denials are deduplicated (CX-sqyc): a repeat denial with
      an identical (holder, current_holder, op) signature since the
      path's last custody change is replied/broadcast but NOT persisted
      — a 1Hz retry loop otherwise floods the append-only store
      (~86k commits/day) until the log doc kills the Bursar.

  (See `Commonplace.Dataflow.Channel` for the blue/red distinction.)
  Writes to `__bursar.json` (CX-i9ca) persist only the permanent-token
  subset and write a fresh full SNAPSHOT doc per persist, so each
  commit's op-log stays O(table) rather than accumulating O(history) —
  safe because the doc has a single writer and is read latest-only (see
  `persist_state/1`).

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

  ## Holder binding (CX-tdkq.32)

  A holder was, until this bead, any string the caller picked — a
  verified agent could acquire/transfer/release a token while claiming
  to be a different holder. `authenticated_as` (an identity string — a
  `SigningContext.identity_uuid` or node-identity id) in `opts` binds
  the effective holder to that authenticated principal:

    * `authenticated_as` present, `holder` nil/omitted — derive:
      `holder := authenticated_as`.
    * `authenticated_as` present, `holder` present and EQUAL — proceed;
      emits `[:commonplace, :bursar, :redundant_holder_param]`
      (evidence for retiring the separate `holder` param later).
    * `authenticated_as` present, `holder` present and DIFFERENT —
      `{:error, :holder_mismatch}` (impersonation attempt), for
      `acquire`, `transfer`'s `from_holder`, and `release`'s `holder`.
    * `authenticated_as` absent — legacy behavior, unchanged (in-domain
      internal callers), but emits `[:commonplace, :bursar,
      :unbound_holder]` so those call sites are enumerable too.

  `renew` is bound the same way as `acquire` — it is the ephemeral
  re-acquire path (move #4), not exempt from the binding.

  This is orthogonal to the pre-existing holder-checked rejection
  (contending against a token actually held by someone else), which is
  unchanged: release/transfer/renew against a token held by someone
  other than the (bound) caller still return `{:error, {:not_holder,
  current_holder}}`.
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
    sweep_interval: 10_000,  # ms between TTL sweep checks
    # CX-sqyc: memory-only memo of denials already persisted to the red
    # log — %{path => MapSet of {holder, current_holder, op}}. A retry
    # loop denied at 1Hz otherwise writes ~86k identical red events/day
    # into the append-only store (this crashed the 2026-07-06 dogfood
    # serve). First denial per signature logs; the memo for a path clears
    # whenever that path's custody changes, so post-transition denials
    # log again. Denied REPLIES/broadcasts are unaffected — only the
    # persisted audit trail is deduplicated.
    denied_memo: %{},
    # CX-i9ca: the last durable-token JSON written to __bursar.json. A
    # mutation that leaves the permanent (ttl:nil) subset unchanged —
    # every ephemeral acquire/release/expiry: the tick-lease/1s, move-locks
    # — persists nothing (the fresh snapshot would be byte-identical). This
    # is what makes ephemeral churn stop touching the store entirely, not
    # merely stop bloating a single doc. `nil` until the first load/persist.
    persisted_content: nil,
    # CX-sfj8/incident (2026-07-12): the node signing context, resolved once at
    # init. Under `local_write_gate: :enforce` the Bursar's OWN writes to
    # `__bursar.json` / `__bursar.log` were UNSIGNED → `{:trust_rejected,
    # :unsigned}` → a retry-loop of denials + durable tokens never persisting.
    # The Bursar is the serve's single-owner authority, so it signs as the NODE
    # (auto-trusted regardless of host). `nil` in embedders/tests with no node
    # identity → falls back to the prior unsigned best-effort behavior.
    node_ctx: nil
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

  `authenticated_as` (CX-tdkq.32) binds the effective holder to an
  authenticated caller identity — see the moduledoc section "Holder
  binding" below. Returns {:ok, token_info}, {:denied, holder_info},
  or {:error, :holder_mismatch} when `holder` conflicts with
  `authenticated_as`.
  """
  def acquire(server \\ __MODULE__, path, holder, opts \\ []) do
    case resolve_holder(holder, opts) do
      {:ok, effective_holder} ->
        ttl_ms = Keyword.get(opts, :ttl, nil)
        GenServer.call(server, {:acquire, path, effective_holder, ttl_ms})

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Release a held token. Only the current holder can release.
  Returns :ok or {:error, reason}.

  `opts[:authenticated_as]` binds the effective holder (CX-tdkq.32) —
  see `acquire/4`.
  """
  def release(server \\ __MODULE__, path, holder, opts \\ []) do
    case resolve_holder(holder, opts) do
      {:ok, effective_holder} -> GenServer.call(server, {:release, path, effective_holder})
      {:error, _} = err -> err
    end
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

  `opts[:authenticated_as]` binds `from_holder` (CX-tdkq.32) — the
  claimed source of a transfer is exactly as impersonable as a release
  holder, so it gets the same check. `to_holder` is not bound; the
  new holder derives its own binding the next time it acts.
  """
  def transfer(server \\ __MODULE__, path, from_holder, to_holder, opts \\ []) do
    case resolve_holder(from_holder, opts) do
      {:ok, effective_from_holder} ->
        GenServer.call(server, {:transfer, path, effective_from_holder, to_holder})

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Renew (keep-alive) a held token. Resets `acquired_at` to now, re-clocking the
  TTL sweep. Options: [ttl: milliseconds] — if provided, updates the TTL value;
  otherwise keeps the existing TTL.
  Returns {:ok, token_info} or {:error, reason}.

  `opts[:authenticated_as]` binds the effective holder (CX-tdkq.32) —
  renew is the ephemeral re-acquire path (move #4), so it is bound
  exactly like `acquire/4`, not exempted.
  """
  def renew(server \\ __MODULE__, path, holder, opts \\ []) do
    case resolve_holder(holder, opts) do
      {:ok, effective_holder} ->
        new_ttl_ms =
          case Keyword.fetch(opts, :ttl) do
            {:ok, v} -> {:set, v}
            :error -> :keep
          end

        GenServer.call(server, {:renew, path, effective_holder, new_ttl_ms})

      {:error, _} = err ->
        err
    end
  end

  # --- Holder binding (CX-tdkq.32) ---
  #
  # Resolve the effective holder from a caller-supplied `holder` plus
  # `opts[:authenticated_as]`. See the moduledoc "Holder binding"
  # section for the full semantics table.
  defp resolve_holder(holder, opts) do
    case Keyword.get(opts, :authenticated_as) do
      nil ->
        :telemetry.execute(
          [:commonplace, :bursar, :unbound_holder],
          %{system_time: System.system_time()},
          %{holder: holder}
        )

        {:ok, holder}

      authenticated_as ->
        cond do
          is_nil(holder) ->
            {:ok, authenticated_as}

          holder == authenticated_as ->
            :telemetry.execute(
              [:commonplace, :bursar, :redundant_holder_param],
              %{system_time: System.system_time()},
              %{holder: holder}
            )

            {:ok, authenticated_as}

          true ->
            {:error, :holder_mismatch}
        end
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.get(opts, :store, CommitStoreClient)

    # Subscribe to magenta commands
    Magenta.subscribe(@magenta_topic)

    # Load or create state. Resolve the node signing context BEFORE load_state so
    # a first-boot seed (create_state_doc / create_log_doc) is signed under enforce.
    node_ctx =
      case Keyword.fetch(opts, :signing_context) do
        {:ok, ctx} ->
          ctx

        :error ->
          case Commonplace.Crypto.NodeIdentity.signing_context() do
            {:ok, ctx} -> ctx
            _ -> nil
          end
      end

    state = %__MODULE__{root_uuid: root_uuid, store: store, node_ctx: node_ctx}
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
        state = %{state | tokens: tokens} |> clear_denials(path)
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
        state = log_denied(state, path, holder, %{current_holder: current_holder})
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
        state = %{state | tokens: tokens} |> clear_denials(path)
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
        state = %{state | tokens: tokens} |> clear_denials(path)
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
        state = %{state | tokens: tokens} |> clear_denials(path)
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
          state = %{state | tokens: tokens} |> clear_denials(path)
          state = persist_state(state)
          ttl_extra = if ttl_ms, do: %{ttl_ms: ttl_ms}, else: %{}
          state = log_event(state, "acquire", path, holder, Map.merge(%{via: "magenta"}, ttl_extra))
          broadcast_green_event("acquired", path, holder)
          {:noreply, state}

        %{holder: ^holder} ->
          # Already held by requester — no-op
          {:noreply, state}

        %{holder: current_holder} ->
          state = log_denied(state, path, holder, %{current_holder: current_holder, via: "magenta"})
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
          state = %{state | tokens: tokens} |> clear_denials(path)
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
            state = %{state | tokens: tokens} |> clear_denials(path)
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
              log_denied(state, path, from_holder, %{
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
            log_denied(state, path, holder, %{
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
        acc = %{acc | tokens: tokens} |> clear_denials(path)
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
                  # CX-i9ca: only permanent (ttl_ms == nil) tokens are ever
                  # persisted now, so every loaded token is permanent and the
                  # re-clock below is a formality — a permanent token never
                  # expires, so its acquired_at is audit-only. (Historically
                  # (move #4) this re-clock granted loaded ttl'd leases a fresh
                  # full TTL; ephemeral leases are no longer persisted at all —
                  # they re-acquire after a restart, guarded from concurrency by
                  # the single-writer Bursar, not by lease survival.) Kept as a
                  # defensive uniform load for any legacy ttl_ms found on disk.
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

    # CX-i9ca: seed the persisted_content cache with the durable serialization
    # of the loaded tokens, so the first post-load mutation that leaves the
    # permanent subset unchanged (an ephemeral acquire) writes nothing, and the
    # first genuine durable change writes exactly once. Uses durable_content so
    # the seed is byte-identical to what persist_state would compare against.
    %{
      state
      | state_uuid: state_uuid,
        log_uuid: log_uuid,
        log: log,
        tokens: tokens,
        persisted_content: durable_content(tokens)
    }
  end

  # CX-i9ca: serialize ONLY permanent (ttl_ms == nil) possession tokens.
  # Ephemeral (ttl'd) tokens — move-locks, the tick-lease, craft-locks — are
  # transient COORDINATION that is harmless (indeed CORRECT) to drop on a
  # crash: no in-flight move survives a restart, the tick lease is re-elected,
  # a craft saga died with its process. Persisting them churned __bursar.json
  # on every move (2 locks) and every tick (1 lease/sec), bloating the doc
  # until persist_state's re-encode wedged the serve (11.5 GB OOM,
  # 2026-07-10). Anti-raid/anti-dupe still enforce on the IN-MEMORY
  # authoritative state.tokens; only durable OWNERSHIP must survive a restart,
  # and that is exactly the ttl_ms == nil set. Shared by persist_state (write)
  # and load_state (seed the persisted_content cache) so the byte-for-byte
  # serialization is identical — the skip-if-unchanged compare depends on it.
  defp durable_content(tokens) do
    durable =
      for {path, %{ttl_ms: nil} = info} <- tokens, into: %{} do
        {path, info}
      end

    json =
      Map.new(durable, fn {path, %{holder: holder, acquired_at: at}} ->
        {path, %{"holder" => holder, "acquired_at" => DateTime.to_iso8601(at)}}
      end)

    Jason.encode!(json, pretty: true)
  end

  defp persist_state(state) do
    new_content = durable_content(state.tokens)

    # CX-i9ca: SKIP an unchanged durable set. Ephemeral acquire/release/expiry
    # (the tick-lease every second, a move-lock per move) leave the permanent
    # subset untouched, so the fresh snapshot would be byte-identical to the
    # last one written — committing it would append ~86k no-op commits/day to
    # the append-only store (the same failure mode CX-sqyc fixed for the red
    # log). Only a real durable change writes.
    if new_content == state.persisted_content do
      state
    else
      persist_snapshot(state, new_content)
    end
  end

  defp persist_snapshot(state, new_content) do
    # CX-i9ca: FRESH-DOC-PER-PERSIST. Each persist writes a self-contained full
    # SNAPSHOT of the durable table into a brand-new doc, rather than
    # reconstructing the prior doc and diffing onto it (the CX-pyi pattern,
    # now retired). Diff-onto-previous accumulated the Yjs op-log without
    # bound, so encode_update's cost grew O(history) per op; a fresh doc keeps
    # each commit's op-log O(table).
    #
    # SAFETY (confirmed with plan #7461): full-snapshot commits are safe here
    # because the state doc has exactly ONE writer and is read latest-only —
    #   (1) reconstruct_snapshot applies ONLY the latest commit to a fresh doc
    #       (doc_builder.ex), never merging the chain; and
    #   (2) __bursar.json is NEVER CRDT-synced across replicas — the Bursar is
    #       a :global singleton (one writer; moduledoc "written only by the
    #       bursar"), GitBridge exporter/inbound skip "__"-prefixed entries,
    #       and Sync.Agent filters them from the filesystem.
    # With a single writer and latest-only reads there is no second branch to
    # merge, so a full snapshot cannot double-count. stable_client_id is kept
    # for a bounded SV slot but is not load-bearing for correctness here.
    doc = Yelixer.Doc.new(client_id: stable_client_id(state.state_uuid))
    doc = ContentType.create(doc, :text, @state_doc)
    doc = ContentType.insert_text(doc, 0, new_content)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(state.store, state.state_uuid, update, %{}, sign_opts(state))

    %{state | persisted_content: new_content}
  end

  # CX-sfj8/incident: sign the Bursar's own durable writes as the NODE under
  # enforce (`[]` when no node identity → prior unsigned best-effort).
  defp sign_opts(%__MODULE__{node_ctx: nil}), do: []
  defp sign_opts(%__MODULE__{node_ctx: ctx}), do: [signing_context: ctx]

  defp log_event(state, event_type, path, holder, extra \\ %{}) do
    event = Map.merge(extra, %{
      "event" => event_type,
      "path" => path,
      "holder" => holder,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })

    log = RedLog.append_raw(state.log, event)

    case RedLog.commit(log, sign_opts(state)) do
      {:ok, committed_log} ->
        %{state | log: committed_log}

      {:error, reason} ->
        :telemetry.execute(
          [:commonplace, :bursar, :red_log_write_failed],
          %{system_time: System.system_time()},
          %{event: event_type, path: path, reason: reason}
        )

        Logger.warning(
          "Bursar: red-log write failed event=#{event_type} path=#{inspect(path)} reason=#{inspect(reason)}"
        )

        state
    end
  end

  # CX-sqyc: persist a denied event only the first time this exact
  # (holder, current_holder, op) signature is denied for the path since
  # the path's last custody change. See :denied_memo in the struct.
  defp log_denied(state, path, holder, extra) do
    sig = {holder, extra[:current_holder], extra[:op]}
    seen = Map.get(state.denied_memo, path, MapSet.new())

    if MapSet.member?(seen, sig) do
      state
    else
      state = %{state | denied_memo: Map.put(state.denied_memo, path, MapSet.put(seen, sig))}
      log_event(state, "denied", path, holder, extra)
    end
  end

  # Custody changed for the path — the next denial is news again.
  defp clear_denials(state, path) do
    %{state | denied_memo: Map.delete(state.denied_memo, path)}
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
    CommitStoreClient.create_commit(state.store, uuid, update, nil, %{}, sign_opts(state))

    # Add to schema
    schema = Schema.add_file(schema, @state_doc, uuid)
    schema_update = Yelixer.Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(state.store, state.root_uuid, schema_update, %{}, sign_opts(state))

    uuid
  end

  defp create_log_doc(state, _schema) do
    uuid = UUID.uuid4()
    log = RedLog.new(uuid, state.store)

    case RedLog.commit(log, sign_opts(state)) do
      {:ok, _log} ->
        # Reload schema (may have been updated by create_state_doc)
        schema = load_root_schema(state)
        schema = Schema.add_file(schema, @log_doc, uuid)
        schema_update = Yelixer.Encoding.encode_update(schema)
        CommitStoreClient.create_chained_commit(state.store, state.root_uuid, schema_update, %{}, sign_opts(state))

        uuid

      {:error, reason} ->
        # CX-2jfb review: DEGRADE, DO NOT DIE. The dangling-entry hazard is
        # already closed above — the schema entry is only written on {:ok},
        # so a refused log-doc creation leaves no pointer to a commit-less
        # doc either way. Exiting here would additionally take the Bursar
        # down, and `create_log_doc/2` runs inside `init/1` under a
        # `restart: :permanent` child spec (application.ex:403-416), so a
        # refusal would become a BOOT CRASH LOOP and then a supervisor
        # shutdown — on any enforce node whose signing context is
        # unresolvable (`sign_opts/1` returns `[]` when `node_ctx` is nil,
        # which is exactly the masked/absent-node-key case of CX-cj59).
        #
        # That inverts this codebase's own stated rule, eleven lines of
        # comment away in a neighbouring trust module
        # (`AuditDispatcher.offer/2`): "losing its RECORD must never turn
        # into losing its ENFORCEMENT." The Bursar is the custody manager;
        # its log failing must not stop it holding tokens.
        Logger.error(
          "Bursar: red-log DOC CREATION refused (#{inspect(reason)}) — no schema entry was " <>
            "written, so nothing points at the commit-less doc. Custody enforcement continues; " <>
            "EVENT LOGGING IS DEGRADED until the write path accepts this writer."
        )

        :telemetry.execute(
          [:commonplace, :bursar, :red_log_create_failed],
          %{system_time: System.system_time()},
          %{uuid: uuid, reason: reason}
        )

        uuid
    end
  end

  # CX-pyi: stable client_id keeps the SV at one slot per state doc
  # across many persist_state calls.
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end
end
