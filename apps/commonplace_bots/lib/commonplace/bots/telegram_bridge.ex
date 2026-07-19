defmodule Commonplace.Bots.TelegramBridge do
  @moduledoc """
  Camillo C4 — a bidirectional mirror between a Telegram chat and the bot's
  `home/tg/<room>/_messages` doc (`Commonplace.Bots.TgRoom`), via an injected
  `Commonplace.Bots.TelegramBridge.Transport`.

  Modeled directly on `Commonplace.Chat.LoomBridge` (own key/SigningContext
  principal, a tick, positional cursor, paused state, red events) — see that
  module's moduledoc for the sibling shape this one mirrors. Read it first;
  only the DIFFERENCES from it are documented in full below.

  ## OFFLINE-ONLY, by construction

  Exactly like `LoomBridge`: this module never dials a socket. It calls
  `Transport.relay_to_external/2` (OUTBOUND only) and reacts to plain
  `{:external_message, %{nick:, text:, chat_id:, handle:}}` messages sent to
  its own pid (INBOUND). Every test exercises the real bridge logic through a
  fake transport — no Telegram client, no network I/O, anywhere in this
  module. The real long-poll adapter is `Commonplace.Bots.TelegramBridge.Poller`
  (a SEPARATE, not-auto-started process — see its moduledoc).

  ## Bridge principal (v1 grantor stance)

  `AgentKeys.ensure("tg-bridge:" <> room, secret_store)` — the same
  bridge-key-custody pattern `LoomBridge` uses (`"loom-bridge:" <> room`),
  just a different custody-slot prefix. The bridge's WRITE authority into
  `_messages` is a `{:docs, [messages_uuid]}` `Commonplace.Trust.Capability`
  cert — see `Commonplace.Bots.TgRoom`'s moduledoc "THE CARVE-RULE WALL" for
  why a subtree/zone-stamp cert cannot cover an array-content `_messages` doc,
  and `issue_write_cert/3` for how that cert is minted. **Issuance happens at
  provision time, NOT inside this module** — the cert's CID list arrives
  ready-made as `opts[:cert_cids]`; this module only threads it through to
  `Commonplace.Chat.Actions.post_message/3`.

  In v1 that cert is NODE-issued (the C3a "default-closed tool allowlist"
  stance: the landlord grants the tenant access to a room it minted) — a
  landlord-imposed grant, not owner-consented delivery. **Future**: once
  cert-delegation lands (CX-8yzt / cert-threading family), the bot itself
  should delegate the bridge a narrower cert out of its own citizenship
  authority instead — the bot inviting the bridge into its own parlor.
  Upgrade then; see `TgRoom`'s moduledoc for the same note in more detail.

  ## INBOUND (Telegram -> room) — attribution, not identity

  A `{:external_message, %{nick:, text:, chat_id:, handle:}}` message is
  posted via `Commonplace.Chat.Actions.post_message/3`, signed with the
  bridge's OWN `SigningContext`, `signer_id: state.identity_uuid`,
  `author_path: "<nick> (via Telegram)"` (attribution metadata — NEVER
  identity; only the bridge's key has cryptographic backing), and
  `cert_cids: state.cert_cids` so the post lands under enforce.

  ## Owner-gated channel binding (TOFU-CLOSED — supersedes "first inbound
  binds", cp-plan design-gate 2026-07-19)

  A first-inbound-binds rule is a TOFU hole: any stranger who DMs the bot
  before its owner does would bind the channel and speak with claimed-author
  attribution from then on. Binding is therefore driven ENTIRELY by
  operator config, read once at `init/1` (never re-read after — a config
  change requires a restart, deliberately, so a running bridge's binding
  can't be silently swapped underneath it):

    * `opts[:owner_chat_id]` set → ONLY that chat_id is ever accepted;
      `bound_chat_id` is set to it immediately at init (no inbound needed
      to establish it). Inbound from any OTHER chat_id is dropped
      (`Logger.warning`, redacted — see below) and NEVER rebinds.
    * else `opts[:owner_handle]` set (case-insensitive TG username, no
      `@`) → `bound_chat_id` starts `nil`; the FIRST inbound whose
      `payload.handle` matches (case-insensitively) binds its `chat_id`.
      Every non-matching inbound, before OR after that bind, is dropped
      and warned — it never rebinds either.
    * neither set → the bridge NEVER binds. Every inbound message is
      dropped and warned; nothing is ever posted to `_messages` from
      Telegram. Fail-closed, not fail-open — no first-comer binding.

  Outbound relays ONLY to `bound_chat_id`. While unbound, `tick_now/1`
  relays nothing — the SAME criterion-3-filtered entries are still found,
  but the tick halts before calling the transport (`status/1` surfaces
  `awaiting_bind: true`) and the cursor is NOT advanced past them, so once
  binding happens (an owner-handle match) they deliver on the next tick
  rather than being silently lost.

  `handle`/`chat_id` (the owner's personal Telegram identifiers) get the
  SAME no-log discipline as the Poller's token: never in a `Logger` message
  verbatim (warnings redact to `"<redacted>"`) and never in `inspect/1` of
  this GenServer's state (see the `Inspect` impl on `State` below).

  ## OUTBOUND (room -> Telegram) — CRITERION-3 FILTER (stricter than LoomBridge)

  `LoomBridge`'s outbound skip is "not bridge-origin" (relay everything
  except the bridge's own echo). This bridge's outbound skip is the
  OPPOSITE shape and much narrower: relay ONLY entries whose
  `author_signer_id` equals `opts[:bot_identity_uuid]` (the bot's OWN
  `Commonplace.Crypto.Signing.signer_id/2` fingerprint — the SAME value the
  bot's `post_message` tool call already stamps onto its own chat posts, C1
  convention). Every other entry — the bridge's own inbound-relayed posts,
  any third-party human signer who somehow posted directly into
  `_messages`, unsigned noise — is SKIPPED, never relayed, but STILL
  advances the cursor (correctly handled, not a failure). This is the
  "only the bot's own words go out to Telegram" rule: a chat room can carry
  other traffic (other citizens, other bots) that must never leak onto the
  Telegram side just because it shares a `_messages` doc.

  ## No reflection window (unlike LoomBridge)

  `LoomBridge` keeps a `@recent_relayed_window` of `{author, text}` pairs to
  drop IRC's echo of its own PRIVMSG back through `getUpdates`-equivalent
  traffic. Telegram's Bot API `getUpdates` NEVER returns the bot's own
  `sendMessage` calls — a bot cannot see its own messages via long-polling,
  by protocol design — so that whole mechanism has no counterpart here.
  Echo prevention on THIS side is entirely the criterion-3 filter above
  (outbound) plus the fact that inbound traffic is real Telegram users, not
  a wire that could reflect our own sends back at us.

  ## Rate limiting (both directions, in-process — NOT `Bots.RateLimit`)

  A simple sliding-60s-window counter per direction, held in `state`:
  inbound posts over the cap are dropped with a `Logger.warning` (the
  human's message is lost, not queued — matches the pause semantics'
  "no buffering" choice); outbound relays over the cap HALT the tick early
  (cursor stops advancing at the throttled entry, exactly like a transport
  failure) and resume naturally next tick. Deliberately NOT
  `Commonplace.Bots.RateLimit` — that module is dispatcher/room-post
  scoped (per `(room, bot)`, seeded from the room's post history) and
  reused across every worker's own outbound chat posts; this bridge's
  cap is about EXTERNAL wire traffic in each direction, an orthogonal
  concern with its own window.

  ## Kill-switch

  `pause/1` / `resume/1` / `status/1`, identical semantics to `LoomBridge`:
  paused drops inbound and no-ops outbound; red events fire for `:started`,
  `:paused`, `:resumed`, `:relay_failed` (keyed on `messages_uuid`, same
  `Commonplace.Dataflow.PubSub.broadcast_red/2` channel).
  """

  use GenServer
  require Logger

  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.AgentKeys
  alias Commonplace.Dataflow.PubSub
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.SecretStore
  alias Commonplace.Tree.DocBuilder

  @default_interval_ms 15_000
  @default_rate_window_ms 60_000
  @default_inbound_per_minute 20
  @default_outbound_per_minute 20

  defmodule State do
    @moduledoc """
    GenServer state for `Commonplace.Bots.TelegramBridge` — a plain struct
    (not a bare map, unlike `LoomBridge`) SOLELY so it can carry a custom
    `Inspect` implementation that redacts the owner's personal Telegram
    identifiers (`owner_chat_id`, `owner_handle`, `bound_chat_id`) from any
    crash report / `:sys.get_state` dump / test `inspect/1` call — the same
    no-log discipline `TelegramBridge.Poller` applies to the bot token.
    """
    defstruct [
      :room,
      :messages_uuid,
      :store,
      :secret_store,
      :identity_uuid,
      :bot_identity_uuid,
      :cert_cids,
      :transport_mod,
      :transport_state,
      :interval_ms,
      :owner_chat_id,
      :owner_handle,
      :bound_chat_id,
      :inbound_limit,
      :outbound_limit,
      paused: false,
      last_cursor: nil,
      inbound_hits: [],
      outbound_hits: []
    ]
  end

  defimpl Inspect, for: State do
    # Canonical algebra-style impl with an EXPLICIT field allowlist — see
    # `TelegramBridge.Poller.State`'s Inspect impl for the full
    # CONSOLIDATION GOTCHA rationale (found at the C4 mini-gate): a
    # `Map.from_struct`-based dump silently includes any future field
    # nobody remembered to redact; an explicit allowlist here means a new
    # field is redacted-by-default (must be deliberately added to `fields`
    # to show up at all).
    import Inspect.Algebra

    def inspect(state, opts) do
      fields = [
        room: state.room,
        messages_uuid: state.messages_uuid,
        identity_uuid: state.identity_uuid,
        bot_identity_uuid: state.bot_identity_uuid,
        cert_cids: state.cert_cids,
        interval_ms: state.interval_ms,
        owner_chat_id: redact(state.owner_chat_id),
        owner_handle: redact(state.owner_handle),
        bound_chat_id: redact(state.bound_chat_id),
        inbound_limit: state.inbound_limit,
        outbound_limit: state.outbound_limit,
        paused: state.paused,
        last_cursor: state.last_cursor
      ]

      concat(["#Commonplace.Bots.TelegramBridge.State<", to_doc(fields, opts), ">"])
    end

    defp redact(nil), do: nil
    defp redact(_), do: "<redacted>"
  end

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Pause the bridge: relay (both directions) becomes a no-op until `resume/1`."
  def pause(bridge), do: GenServer.call(bridge, :pause)

  @doc "Resume a paused bridge."
  def resume(bridge), do: GenServer.call(bridge, :resume)

  @doc """
  Run one outbound relay cycle synchronously. Returns `{:ok, %{relayed: n}}`,
  `{:ok, :paused}`, `{:ok, :awaiting_bind}` (criterion-3 entries exist but
  no `bound_chat_id` yet — cursor NOT advanced past them), or `{:error, reason}`.
  """
  def tick_now(bridge), do: GenServer.call(bridge, :tick_now, 30_000)

  @doc "Return `%{paused:, room:, messages_uuid:, bridge_identity_uuid:, last_cursor:, bound:}`. `bound` is a boolean — never the raw chat_id/handle."
  def status(bridge), do: GenServer.call(bridge, :status)

  @doc "The bridge's persistent signing identity uuid for `room` — stable custody slot key."
  @spec bridge_identity_uuid(String.t()) :: String.t()
  def bridge_identity_uuid(room), do: "tg-bridge:" <> room

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    room = Keyword.fetch!(opts, :room)
    messages_uuid = Keyword.fetch!(opts, :messages_uuid)
    bot_identity_uuid = Keyword.fetch!(opts, :bot_identity_uuid)
    store = Keyword.get(opts, :store, CommitStoreClient)
    secret_store = Keyword.get(opts, :secret_store, SecretStore)
    transport_mod = Keyword.fetch!(opts, :transport_mod)
    transport_state = Keyword.get(opts, :transport_state)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    cert_cids = Keyword.get(opts, :cert_cids, [])

    identity_uuid = bridge_identity_uuid(room)
    {:ok, _pub} = AgentKeys.ensure(identity_uuid, secret_store)

    owner_chat_id = normalize_chat_id(Keyword.get(opts, :owner_chat_id))
    owner_handle = normalize_handle(Keyword.get(opts, :owner_handle))

    # Owner-chat-id, when configured, is a KNOWN fixed binding — no inbound
    # is needed to establish it (see moduledoc "Owner-gated channel binding").
    bound_chat_id = owner_chat_id

    state = %State{
      room: room,
      messages_uuid: messages_uuid,
      store: store,
      secret_store: secret_store,
      identity_uuid: identity_uuid,
      bot_identity_uuid: bot_identity_uuid,
      cert_cids: cert_cids,
      transport_mod: transport_mod,
      transport_state: transport_state,
      interval_ms: interval_ms,
      owner_chat_id: owner_chat_id,
      owner_handle: owner_handle,
      bound_chat_id: bound_chat_id,
      inbound_limit: Keyword.get(opts, :inbound_per_minute, @default_inbound_per_minute),
      outbound_limit: Keyword.get(opts, :outbound_per_minute, @default_outbound_per_minute),
      paused: false,
      last_cursor: nil,
      inbound_hits: [],
      outbound_hits: []
    }

    schedule_tick(interval_ms)

    PubSub.broadcast_red(messages_uuid, {:telegram_bridge, :started, %{room: room}})

    {:ok, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    PubSub.broadcast_red(state.messages_uuid, {:telegram_bridge, :paused, %{room: state.room}})
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    PubSub.broadcast_red(state.messages_uuid, {:telegram_bridge, :resumed, %{room: state.room}})
    {:reply, :ok, %{state | paused: false}}
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    {result, new_state} = do_tick(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      paused: state.paused,
      room: state.room,
      messages_uuid: state.messages_uuid,
      bridge_identity_uuid: state.identity_uuid,
      last_cursor: state.last_cursor,
      bound: state.bound_chat_id != nil
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, new_state} = do_tick(state)
    schedule_tick(new_state.interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:external_message, %{} = payload}, %{paused: true} = state) do
    Logger.warning(
      "TelegramBridge: dropping inbound external message for #{state.room} — bridge is paused"
    )

    _ = payload
    {:noreply, state}
  end

  def handle_info({:external_message, %{nick: _, text: _, chat_id: _} = payload}, state) do
    {:noreply, handle_external_message(state, payload)}
  end

  # --- Outbound (room -> Telegram) ---

  defp do_tick(%{paused: true} = state), do: {{:ok, :paused}, state}

  defp do_tick(state) do
    case load_messages_doc(state) do
      {:ok, doc} ->
        materialized = Messages.materialize(doc)
        new_entries = entries_since(materialized, state.last_cursor)
        relayable = Enum.filter(new_entries, &bot_origin?(&1, state))

        if relayable != [] and state.bound_chat_id == nil do
          # Cursor NOT advanced — these entries deliver once bound.
          {{:ok, :awaiting_bind}, state}
        else
          {relayed_count, new_state} = relay_entries(new_entries, state)
          {{:ok, %{relayed: relayed_count}}, new_state}
        end

      :none ->
        {{:error, :not_found}, state}
    end
  end

  defp load_messages_doc(state) do
    DocBuilder.reconstruct_snapshot(state.store, state.messages_uuid)
  end

  # Positional cursor, same technique LoomBridge / Commonplace.MCP.Tools.LoomRead
  # use: message ids are random UUIDv4s (unorderable), ts isn't stable across
  # edits — position in the materialized list is the only safe cursor.
  defp entries_since(materialized, nil), do: materialized

  defp entries_since(materialized, cursor) do
    case Enum.find_index(materialized, fn m -> m["id"] == cursor end) do
      nil -> materialized
      idx -> Enum.drop(materialized, idx + 1)
    end
  end

  # THE CRITERION-3 FILTER (see moduledoc): relay ONLY entries the bot
  # itself authored. Everything else (the bridge's own inbound-relayed
  # posts, third-party signers, unsigned noise) is non-relayable but still
  # advances the cursor in `relay_entries/2` below.
  defp bot_origin?(entry, state), do: entry["author_signer_id"] == state.bot_identity_uuid

  # Walks ALL new entries in order (not just the relayable ones) so the
  # cursor advances past every entry seen this tick, relayable or not.
  # Halts (stops advancing) on the first relay failure OR the first
  # rate-limit throttle — both retry next tick, never skip a message.
  defp relay_entries(entries, state) do
    Enum.reduce_while(entries, {0, state}, fn entry, {count, acc_state} ->
      cond do
        not bot_origin?(entry, acc_state) ->
          {:cont, {count, %{acc_state | last_cursor: entry["id"]}}}

        throttled_outbound?(acc_state) ->
          {:halt, {count, acc_state}}

        true ->
          case relay_one(entry, acc_state) do
            {:ok, new_state} ->
              {:cont, {count + 1, %{new_state | last_cursor: entry["id"]}}}

            {:error, reason} ->
              PubSub.broadcast_red(
                acc_state.messages_uuid,
                {:telegram_bridge, :relay_failed,
                 %{room: acc_state.room, reason: reason, message_id: entry["id"]}}
              )

              {:halt, {count, acc_state}}
          end
      end
    end)
  end

  defp relay_one(entry, state) do
    message = %{author: entry["author_path"], text: entry["text"], chat_id: state.bound_chat_id}

    case state.transport_mod.relay_to_external(state.transport_state, message) do
      {:ok, new_transport_state} ->
        {:ok,
         %{
           state
           | transport_state: new_transport_state,
             outbound_hits: record_hit(state.outbound_hits)
         }}

      {:error, _reason} = err ->
        err
    end
  end

  # --- Inbound (Telegram -> room) ---

  defp handle_external_message(state, payload) do
    cond do
      throttled_inbound?(state) ->
        Logger.warning(
          "TelegramBridge: dropping inbound message for #{state.room} — inbound rate limit exceeded"
        )

        state

      true ->
        state = %{state | inbound_hits: record_hit(state.inbound_hits)}
        maybe_bind_and_post(state, payload)
    end
  end

  # Owner-chat-id fixed at init — nothing to bind here, just gate.
  defp maybe_bind_and_post(%{owner_chat_id: owner_chat_id} = state, payload)
       when is_binary(owner_chat_id) do
    chat_id = normalize_chat_id(payload.chat_id)

    if chat_id == owner_chat_id do
      post_inbound(state, payload)
      state
    else
      warn_dropped_unbound(state)
      state
    end
  end

  # Owner-handle mode: first matching handle binds; every non-match (before
  # or after) drops and never rebinds.
  defp maybe_bind_and_post(%{owner_chat_id: nil, owner_handle: owner_handle} = state, payload)
       when is_binary(owner_handle) do
    handle = normalize_handle(Map.get(payload, :handle))

    cond do
      state.bound_chat_id != nil and normalize_chat_id(payload.chat_id) == state.bound_chat_id ->
        post_inbound(state, payload)
        state

      state.bound_chat_id == nil and handle == owner_handle ->
        bound_chat_id = normalize_chat_id(payload.chat_id)
        new_state = %{state | bound_chat_id: bound_chat_id}
        post_inbound(new_state, payload)
        new_state

      true ->
        warn_dropped_unbound(state)
        state
    end
  end

  # Neither owner_chat_id nor owner_handle configured — fail-closed, never
  # binds, everything drops.
  defp maybe_bind_and_post(%{owner_chat_id: nil, owner_handle: nil} = state, _payload) do
    Logger.warning(
      "TelegramBridge: dropping inbound message for #{state.room} — no owner_chat_id/owner_handle configured, refusing to bind"
    )

    state
  end

  defp warn_dropped_unbound(state) do
    Logger.warning(
      "TelegramBridge: dropping inbound message for #{state.room} — chat_id/handle does not match the configured owner binding"
    )
  end

  # The live-found bug (cp-plan follow-up): this used to fire-and-forget
  # `Actions.post_message`'s return — a DENIED write (e.g. an unresolvable
  # capability_proof, the `issue_write_cert/3` persistence bug this same
  # round fixed) vanished with no signal anywhere, a 30-minute hunt on the
  # live serve for what should have been one log line. `{:ok, _}` stays
  # silent (the happy path is not new information); `{:error, reason}`
  # logs `reason` ONLY — never `payload.text`, which is jes's (or whoever
  # DMed the bridge) PRIVATE message content, not something that belongs
  # in a shared log stream — plus a telemetry event so a real deployment
  # can alert on it instead of relying on someone grepping logs.
  defp post_inbound(state, payload) do
    case AgentKeys.signing_context_for(state.identity_uuid, state.secret_store) do
      {:ok, signing_context} ->
        case Actions.post_message(state.messages_uuid, payload.text,
               room: state.room,
               signer_id: state.identity_uuid,
               author_path: attribution(payload.nick),
               signing_context: signing_context,
               cert_cids: state.cert_cids,
               store: state.store
             ) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "TelegramBridge: inbound post FAILED for room #{state.room}: #{inspect(reason)}"
            )

            :telemetry.execute(
              [:commonplace, :bots, :telegram_bridge, :inbound_post_failed],
              %{system_time: System.system_time()},
              %{room: state.room, reason: reason}
            )
        end

      other ->
        Logger.warning(
          "TelegramBridge: no signing context for #{state.identity_uuid}, dropping inbound message: #{inspect(other)}"
        )
    end
  end

  # ATTRIBUTION metadata, not identity: the bridge is the signer
  # (author_signer_id == the bridge's own identity_uuid); this string only
  # records which Telegram nick said it, for display.
  defp attribution(nick), do: "#{nick} (via Telegram)"

  # --- Rate limiting (both directions) ---

  defp throttled_inbound?(state), do: window_count(state.inbound_hits) >= state.inbound_limit
  defp throttled_outbound?(state), do: window_count(state.outbound_hits) >= state.outbound_limit

  defp window_count(hits), do: hits |> prune_hits() |> length()

  defp record_hit(hits), do: [System.monotonic_time(:millisecond) | prune_hits(hits)]

  defp prune_hits(hits) do
    cutoff = System.monotonic_time(:millisecond) - @default_rate_window_ms
    Enum.filter(hits, &(&1 >= cutoff))
  end

  # --- Config normalization (no-log-discipline inputs) ---

  defp normalize_chat_id(nil), do: nil
  defp normalize_chat_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_chat_id(id) when is_binary(id), do: id

  defp normalize_handle(nil), do: nil

  defp normalize_handle(handle) when is_binary(handle) do
    handle |> String.trim_leading("@") |> String.downcase()
  end

  defp schedule_tick(:infinity), do: :ok
  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
