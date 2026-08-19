defmodule Commonplace.Chat.LoomBridge do
  @moduledoc """
  CX-6sf2.2 (A2): a bidirectional mirror between the `loom` chat room
  (CX-6sf2.1 A1 — `Commonplace.Chat.LoomRoom`) and an external channel,
  via an injected `Commonplace.Chat.LoomBridge.Transport`.

  Modeled on `Commonplace.GitBridge.Server` (own key/SigningContext
  principal, a tick, paused state, red events) — see that module's
  moduledoc for the sibling shape this one mirrors.

  ## OFFLINE-ONLY, by construction

  This module never dials a socket. It calls exactly one function on
  the injected transport (`Transport.relay_to_external/2`, OUTBOUND
  only) and otherwise only reacts to plain `{:external_message, %{nick,
  text}}` messages sent to its own pid (INBOUND). Every test in
  `loom_bridge_test.exs` exercises the real bridge logic through a fake
  transport that just forwards to the test process — no IRC client, no
  network I/O, anywhere in this bead. Wiring a real IRC adapter over
  `Transport` is a separate, human-gated follow-up (see the seam
  module's moduledoc) — `#loom` is the team's live channel and a
  mis-wired bridge could disrupt it.

  ## OUTBOUND (loom -> external)

  On a tick (`tick_now/1` synchronously, or the internal `:tick`
  timer), `Messages.materialize/1` the room's `_messages` doc and take
  the tail after the last-relayed-outbound cursor — the SAME positional
  cursor technique `loom_read` uses (message ids are random UUIDv4s, not
  orderable; `ts` isn't stable across edits — see
  `Commonplace.MCP.Tools.LoomRead` moduledoc for why position, not id
  value or ts, is the only safe cursor). For each new message NOT marked
  bridge-origin (see echo prevention below), call
  `transport.relay_to_external/2` in order; a `{:error, _}` halts the
  scan for this tick (retried next tick, nothing skipped). The cursor
  only advances past messages that were successfully relayed OR
  correctly skipped as bridge-origin — never past a failed relay.

  ## INBOUND (external -> loom)

  A `{:external_message, %{nick:, text:}}` message (from a real
  adapter's `send/2`, or a test's fake transport) is posted to the loom
  room via `Commonplace.Chat.Actions.post_message/3`, signed with the
  bridge's OWN `SigningContext` (the bridge is the cryptographic
  PRINCIPAL — see "Bridge principal" below). The IRC nick is carried as
  ATTRIBUTION metadata in `author_path` (formatted `"<nick> (via IRC)"`)
  — mirroring GitBridge's `Commonplace-Authors` trailer idea: the
  signer and the attributed human are different things, and only the
  signer has cryptographic backing.

  ## Echo prevention (the two-way-sync trap) — THE INVARIANT

  A message the bridge itself posted to loom (from an inbound IRC line)
  must NEVER be relayed back out to IRC, and a message relayed out to
  IRC must NEVER come back in and get re-posted to loom. Two distinct
  mechanisms, one per direction:

    * **Outbound skip (loom-origin marker)**: every message the bridge
      posts to loom carries `author_signer_id` equal to the bridge's
      OWN signing identity (`bridge_identity_uuid/1`). The outbound scan
      skips any materialized entry whose `author_signer_id` matches —
      no separate flag needed, the signer IS the marker, and it's
      already tamper-evident (only the bridge's key can produce it).
    * **Inbound dedup (recent-relayed window)**: the bridge remembers
      the last `@recent_relayed_window` `{author, text}` pairs it
      successfully relayed OUT. An inbound `{nick, text}` that matches
      one of those pairs is treated as an IRC-side reflection of our
      own relay (not a new human message) — it is dropped, NOT posted
      to loom, and the matched entry is consumed (removed) from the
      window so a later, genuinely-repeated human message with the same
      text isn't blocked forever.

  This mirrors GitBridge's "last-pushed / last-ingested" bookkeeping:
  one cursor/marker per direction, checked before acting in the OTHER
  direction.

  ## Kill-switch

  `pause/1` / `resume/1` / `status/1`. Paused: `tick_now/1` and the
  internal timer no-op (`{:ok, :paused}`, no relay calls), and inbound
  `{:external_message, _}` messages are DROPPED with a `Logger.warning`
  (v1 choice — no queueing/replay-on-resume; a paused bridge is a full
  stop, not a buffer). Red events (`Commonplace.Dataflow.PubSub.broadcast_red/2`,
  keyed on `messages_uuid`) fire for `:started`, `:paused`, `:resumed`,
  and `:relay_failed`.

  ## Bridge principal

  Reuses the `Commonplace.Crypto.AgentKeys` bridge-key-custody pattern
  from `Commonplace.GitBridge.Inbound.bridge_identity_uuid/1`: an
  idempotent per-room identity slot, `"loom-bridge:" <> room`, minted
  via `AgentKeys.ensure/2` and threaded as a `SigningContext` on every
  inbound-posted loom message.
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
  @recent_relayed_window 50

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
  Run one outbound relay cycle synchronously. Returns `{:ok, %{relayed: n}}`
  (n new, non-echo messages successfully relayed this tick), `{:ok,
  :paused}` if paused, or `{:error, reason}` if the messages doc can't
  be loaded.
  """
  def tick_now(bridge), do: GenServer.call(bridge, :tick_now, 30_000)

  @doc "Return `%{paused:, room:, messages_uuid:, bridge_identity_uuid:, last_cursor:}`."
  def status(bridge), do: GenServer.call(bridge, :status)

  @doc "The bridge's persistent signing identity uuid for `room` — stable custody slot key."
  @spec bridge_identity_uuid(String.t()) :: String.t()
  def bridge_identity_uuid(room), do: "loom-bridge:" <> room

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    room = Keyword.fetch!(opts, :room)
    messages_uuid = Keyword.fetch!(opts, :messages_uuid)
    store = Keyword.get(opts, :store, CommitStoreClient)
    secret_store = Keyword.get(opts, :secret_store, SecretStore)
    transport_mod = Keyword.fetch!(opts, :transport_mod)
    transport_state = Keyword.get(opts, :transport_state)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    identity_uuid = bridge_identity_uuid(room)
    {:ok, _pub} = AgentKeys.ensure(identity_uuid, secret_store)

    state = %{
      room: room,
      messages_uuid: messages_uuid,
      store: store,
      secret_store: secret_store,
      identity_uuid: identity_uuid,
      transport_mod: transport_mod,
      transport_state: transport_state,
      interval_ms: interval_ms,
      paused: false,
      last_cursor: nil,
      recent_relayed: []
    }

    schedule_tick(interval_ms)

    PubSub.broadcast_red(messages_uuid, {:loom_bridge, :started, %{room: room}})

    {:ok, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    PubSub.broadcast_red(state.messages_uuid, {:loom_bridge, :paused, %{room: state.room}})
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    PubSub.broadcast_red(state.messages_uuid, {:loom_bridge, :resumed, %{room: state.room}})
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
      last_cursor: state.last_cursor
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
      "LoomBridge: dropping inbound external message for #{state.room} — bridge is paused"
    )

    _ = payload
    {:noreply, state}
  end

  def handle_info({:external_message, %{nick: nick, text: text}}, state) do
    {:noreply, handle_external_message(state, nick, text)}
  end

  # --- Outbound (loom -> external) ---

  defp do_tick(%{paused: true} = state), do: {{:ok, :paused}, state}

  defp do_tick(state) do
    case load_messages_doc(state) do
      {:ok, doc} ->
        materialized = Messages.materialize(doc)
        new_entries = entries_since(materialized, state.last_cursor)
        {relayed_count, new_state} = relay_entries(new_entries, state)
        {{:ok, %{relayed: relayed_count}}, new_state}

      :none ->
        {{:error, :not_found}, state}
    end
  end

  defp load_messages_doc(state) do
    DocBuilder.reconstruct_snapshot(state.store, state.messages_uuid)
  end

  # Positional cursor, same technique as Commonplace.MCP.Tools.LoomRead:
  # find the last-cursor id's index and take everything after it. A
  # stale/unknown cursor (nil, or an id that's since fallen out of
  # history) falls back to the full materialized list.
  defp entries_since(materialized, nil), do: materialized

  defp entries_since(materialized, cursor) do
    case Enum.find_index(materialized, fn m -> m["id"] == cursor end) do
      nil -> materialized
      idx -> Enum.drop(materialized, idx + 1)
    end
  end

  # Walks entries in order; relays each non-echo entry via the
  # transport. Halts (stops advancing the cursor) on the first relay
  # failure so a transient transport error retries that SAME message
  # next tick rather than skipping it. Bridge-origin entries (posted by
  # this bridge itself, from an inbound IRC line) are skipped — never
  # relayed — but DO still advance the cursor, since they were
  # correctly handled (not a failure).
  defp relay_entries(entries, state) do
    Enum.reduce_while(entries, {0, state}, fn entry, {count, acc_state} ->
      cond do
        bridge_origin?(entry, acc_state) ->
          {:cont, {count, %{acc_state | last_cursor: entry["id"]}}}

        true ->
          case relay_one(entry, acc_state) do
            {:ok, new_state} ->
              {:cont, {count + 1, %{new_state | last_cursor: entry["id"]}}}

            {:error, reason} ->
              PubSub.broadcast_red(
                acc_state.messages_uuid,
                {:loom_bridge, :relay_failed,
                 %{room: acc_state.room, reason: reason, message_id: entry["id"]}}
              )

              {:halt, {count, acc_state}}
          end
      end
    end)
  end

  defp bridge_origin?(entry, state), do: entry["author_signer_id"] == state.identity_uuid

  defp relay_one(entry, state) do
    message = %{author: entry["author_path"], text: entry["text"]}

    case state.transport_mod.relay_to_external(state.transport_state, message) do
      {:ok, new_transport_state} ->
        recent = remember_relayed(state.recent_relayed, message)
        {:ok, %{state | transport_state: new_transport_state, recent_relayed: recent}}

      {:error, _reason} = err ->
        err
    end
  end

  defp remember_relayed(recent, message) do
    identity = {message.author, message.text}
    Enum.take([identity | recent], @recent_relayed_window)
  end

  # --- Inbound (external -> loom) ---

  defp handle_external_message(state, nick, text) do
    identity = {nick, text}

    if reflection?(state.recent_relayed, identity) do
      # IRC reflecting our own relay back at us — drop, don't repost,
      # and consume the matched window entry so a later genuine repeat
      # of the same text isn't blocked forever.
      %{state | recent_relayed: List.delete(state.recent_relayed, identity)}
    else
      post_inbound(state, nick, text)
      state
    end
  end

  defp reflection?(recent_relayed, identity), do: identity in recent_relayed

  defp post_inbound(state, nick, text) do
    case AgentKeys.signing_context_for(state.identity_uuid, state.secret_store) do
      {:ok, signing_context} ->
        Actions.post_message(state.messages_uuid, text,
          room: state.room,
          signer_id: state.identity_uuid,
          author_path: attribution(nick),
          signing_context: signing_context,
          store: state.store
        )

      other ->
        Logger.warning(
          "LoomBridge: no signing context for #{state.identity_uuid}, dropping inbound message: #{inspect(other)}"
        )
    end
  end

  # ATTRIBUTION metadata, not identity: the bridge is the signer
  # (author_signer_id == the bridge's own identity_uuid); this string
  # only records which IRC nick said it, for display.
  defp attribution(nick), do: "#{nick} (via IRC)"

  defp schedule_tick(:infinity), do: :ok
  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
