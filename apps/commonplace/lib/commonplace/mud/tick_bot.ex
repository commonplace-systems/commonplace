defmodule Commonplace.MUD.TickBot do
  @moduledoc """
  Singleton tick scheduler for the MUD (P2 of CX-v55j).

  Wakes every `heartbeat_ms` (default 1000), walks the world tree from
  the configured root, and fires per-doc tick handlers for any doc
  whose `tick_interval_ms` has elapsed since its last firing.

  v0 scope (per spec §4): in-memory `last_tick` per doc UUID; if a tick
  overruns the heartbeat we drop the next firing rather than queue.
  Expects dozens of tickers, not thousands.

  Tick handler for v0 is a built-in: if the doc has a `tick_message`
  field, broadcast `%{kind: :custom, text: tick_message}` as a red
  event to the containing room. Rooms broadcast to themselves; objects
  broadcast to their parent room. User-authored `tick.elx` verbs are
  P3 (hot-reloaded via `Commonplace.Code.SourceDoc.compile/2`).

  ## Lease-based leadership (move #4, CX-tdkq.7)

  The `{:global, __MODULE__}` registration is retired — `:global`
  name-conflict resolution on node join could kill or orphan the
  singleton, and a netsplit allowed two tickers. Instead, every TickBot
  instance is locally registered and contends for one green-token
  lease (`"__singletons/tick_bot"`) each tick:

    * the holder ticks and keep-alives the lease (renew at TTL/3 —
      memory-only on the Bursar side);
    * non-holders skip the tick and retry next heartbeat;
    * a dead leader's lease expires after `lease_ttl_ms` and another
      instance takes over (failover bounded by the TTL);
    * no Bursar reachable (no local, no remote serve — e.g. a bare
      `mix run` temp node) ⇒ `{:error, :bursar_unavailable}` ⇒ idle.
      Fail-closed: the process exists everywhere, but it can only
      tick where the cluster's lock authority grants it.

  ## Single instance + denial containment (CX-sqyc)

  Two contending TickBots retrying acquire at 1Hz turned serve-fatal:
  each denial persisted a red event, bloating `__bursar.log` until the
  Bursar crashed. Three rules keep contention from ever storming again:

    * **remote clients never contend** — on a node where
      `CommitStoreClient.remote_node/0` is `{:ok, _}` (the MCP escript,
      any attached client), the tick singleton is the SERVE's job
      (CX-l4yv); this instance idles without touching the lease.
    * **backoff-to-TTL** — a denied contender sleeps until the current
      lease could have expired (`lease_ttl_ms`) instead of re-acquiring
      every heartbeat. Failover latency is unchanged (bounded by TTL).
    * **boot orphan sweep** (`orphan_sweep:` opt, default true) — on the
      singleton host, the first denial after boot force-releases and
      retakes the lease, once: with remote clients gated out, any other
      holder on the host is a dead incarnation's re-clocked lease.
      (The Bursar independently suppresses repeat-identical denial
      events from the red log.)
  """

  use GenServer
  require Logger

  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Schemas, VerbSource, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  @default_heartbeat_ms 1000
  @lease_path "__singletons/tick_bot"
  @default_lease_ttl_ms 60_000

  defstruct [
    :root_uuid,
    :store,
    :heartbeat_ms,
    :last_tick,
    :bursar,
    :holder,
    :lease_ttl_ms,
    :last_renew,
    :denied_until,
    :orphan_sweep,
    :swept
  ]

  ## Client

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @doc """
  Force an immediate tick scan (for tests). Synchronous. Returns `:ok`
  when this instance holds the tick lease and ticked, `:not_leader`
  when the lease is held elsewhere or no Bursar is reachable.
  """
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now, 10_000)

  ## Server

  @impl true
  def init(opts) do
    state = %__MODULE__{
      root_uuid: Keyword.get(opts, :root_uuid),
      store: Keyword.get(opts, :store, CommitStoreClient),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, @default_heartbeat_ms),
      last_tick: %{},
      bursar: Keyword.get(opts, :bursar, Bursar),
      holder: Keyword.get(opts, :holder, default_holder()),
      # Failover latency is bounded by this TTL; embedders that need a
      # tighter bound configure :tick_lease_ttl_ms (Application children
      # carry no opts).
      lease_ttl_ms:
        Keyword.get(opts, :lease_ttl_ms) ||
          Application.get_env(:commonplace, :tick_lease_ttl_ms, @default_lease_ttl_ms),
      last_renew: nil,
      denied_until: nil,
      orphan_sweep: Keyword.get(opts, :orphan_sweep, true),
      swept: false
    }

    if Keyword.get(opts, :auto_start, true) do
      schedule_tick(state.heartbeat_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_leader?, new_state} = maybe_tick(state)
    schedule_tick(state.heartbeat_ms)
    {:noreply, new_state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick_now, _from, state) do
    case maybe_tick(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:not_leader, new_state} -> {:reply, :not_leader, new_state}
    end
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  # CX-tdkq.32: the default holder is a NAMED principal, never a free
  # string — it's prefixed with the node identity so the Bursar's
  # `authenticated_as` binding (see `Commonplace.Green.Bursar` moduledoc
  # "Holder binding") ties this lease to an accountable signer, not
  # just whatever `node()` happened to return. Falls back to the old
  # unprefixed form only if the node identity is unavailable (fresh
  # data_dir failure) so TickBot still degrades rather than crashing.
  defp default_holder do
    case Commonplace.Crypto.NodeIdentity.identity() do
      {:ok, node_identity} -> "#{node_identity}/tick_bot@#{node()}"
      {:error, _} -> "tick_bot@#{node()}"
    end
  end

  ## Leadership lease

  defp maybe_tick(state) do
    case ensure_leader(state) do
      {:leader, state} -> {:ok, run_tick(state)}
      {:not_leader, state} -> {:not_leader, state}
    end
  end

  # Acquire is idempotent for the current holder but does NOT re-clock
  # the lease — keep-alive is renew's job, fired at TTL/3 (and
  # immediately on first leadership observation, which also covers a
  # supervisor-restarted leader inheriting its own stale-clocked token).
  defp ensure_leader(state) do
    cond do
      # CX-sqyc / CX-l4yv: singletons are hosted on the serve. A remote
      # client node (MCP escript, attached CLI) must never contend for
      # the tick lease — its acquire attempts are pure denial noise.
      remote_client?() ->
        {:not_leader, %{state | last_renew: nil}}

      backing_off?(state) ->
        {:not_leader, state}

      true ->
        attempt_acquire(state)
    end
  end

  defp remote_client?, do: match?({:ok, _}, CommitStoreClient.remote_node())

  defp backing_off?(%{denied_until: nil}), do: false

  defp backing_off?(%{denied_until: until}),
    do: System.monotonic_time(:millisecond) < until

  defp attempt_acquire(state) do
    # holder: nil + authenticated_as: state.holder is the derive path
    # (Bursar.resolve_holder) — no redundant_holder_param noise every
    # heartbeat, same bound effective holder either way.
    case BursarClient.acquire(state.bursar, @lease_path, nil,
           ttl: state.lease_ttl_ms,
           authenticated_as: state.holder
         ) do
      {:ok, _} ->
        # Leadership proves no orphan is blocking us — retire the boot
        # sweep so a LATER denial (lease legitimately moved after expiry)
        # backs off instead of stealing.
        {:leader, maybe_renew(%{state | denied_until: nil, swept: true})}

      {:denied, _} ->
        handle_denied(state)

      # :bursar_unavailable — no lock authority reachable, so never tick
      # (fail-closed; the bare-mix-run temp-node case). No backoff: when
      # the serve comes back the next heartbeat may contend immediately.
      {:error, _} ->
        {:not_leader, %{state | last_renew: nil}}
    end
  end

  # CX-sqyc boot orphan sweep: on the singleton host (remote clients are
  # gated out above), a denial BEFORE this process has ever led means
  # the lease is held by a dead incarnation (re-clocked to a full TTL by
  # the Bursar's load_state) — break it and retake, once per process
  # lifetime (`swept` also flips on first leadership). Any later denial
  # backs off for a full lease TTL instead of hammering acquire every
  # heartbeat.
  defp handle_denied(%{orphan_sweep: true, swept: false} = state) do
    state = %{state | swept: true}

    with :ok <- BursarClient.force_release(state.bursar, @lease_path),
         {:ok, _} <-
           BursarClient.acquire(state.bursar, @lease_path, nil,
             ttl: state.lease_ttl_ms,
             authenticated_as: state.holder
           ) do
      Logger.info("TickBot: swept orphaned tick lease and took over")
      {:leader, maybe_renew(%{state | denied_until: nil})}
    else
      _ -> {:not_leader, backoff(state)}
    end
  end

  defp handle_denied(state), do: {:not_leader, backoff(state)}

  defp backoff(state) do
    %{
      state
      | last_renew: nil,
        denied_until: System.monotonic_time(:millisecond) + state.lease_ttl_ms
    }
  end

  defp maybe_renew(state) do
    now = System.monotonic_time(:millisecond)

    if state.last_renew == nil or now - state.last_renew >= div(state.lease_ttl_ms, 3) do
      _ =
        BursarClient.renew(state.bursar, @lease_path, nil, authenticated_as: state.holder)

      %{state | last_renew: now}
    else
      state
    end
  end

  defp run_tick(%__MODULE__{root_uuid: nil} = state) do
    case Commonplace.Workspace.root_uuid() do
      {:ok, uuid} -> run_tick(%{state | root_uuid: uuid})
      _ -> state
    end
  end

  defp run_tick(%__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)
    tickers = collect_tickers(state.root_uuid, state.store)

    new_last_tick =
      Enum.reduce(tickers, state.last_tick, fn ticker, acc ->
        case Map.get(acc, ticker.uuid) do
          nil ->
            fire(ticker, state.store)
            Map.put(acc, ticker.uuid, now)

          last when now - last >= ticker.interval_ms ->
            fire(ticker, state.store)
            Map.put(acc, ticker.uuid, now)

          _ ->
            acc
        end
      end)

    %{state | last_tick: new_last_tick}
  end

  # CX-qom0: a legacy (full-defmodule, ambient-reach) `tick.elx` is no
  # longer dispatchable here at all — that was the confused-deputy
  # ingress: TickBot is a SYSTEM caller (not the player-dispatch path
  # `Verbs.run_legacy_user_verb/5` gates), so a plantable legacy verb on
  # any ticking room/object got full store/uuid reach on every heartbeat,
  # for free, without ever going through a player. Only a SAFE
  # (`tick.safe.elx`) verb can fire on tick now; a clean `:not_found`
  # falls back to the built-in `tick_message` broadcast (unchanged
  # behavior for every room/object that never authored a tick verb at
  # all).
  defp fire(%{uuid: host_uuid, room_uuid: room_uuid, message: msg, kind: kind}, store) do
    case VerbSource.find_safe_source(host_uuid, "tick", store) do
      {:ok, _source_uuid} ->
        object_uuid = if kind == :object, do: host_uuid, else: nil
        ctx = %{current_room_uuid: room_uuid, store: store}
        facade = Facade.new(ctx, object_uuid, [host_uuid], nil, store)

        case VerbSource.run_safe_verb(host_uuid, "tick", [host_uuid], facade, %{}, store) do
          {:ok, _} ->
            :ok

          {:error, {:runtime_error, reason}} ->
            World.broadcast_room(room_uuid, %{kind: :verb_error, verb: "tick", reason: reason})
            :ok

          {:error, {:compile_error, reason}} ->
            World.broadcast_room(room_uuid, %{kind: :verb_error, verb: "tick", reason: reason})
            :ok

          {:error, {:unsafe_verb, reason}} ->
            World.broadcast_room(room_uuid, %{
              kind: :verb_error,
              verb: "tick",
              reason: inspect(reason)
            })

            :ok

          _ ->
            if msg, do: World.broadcast_room(room_uuid, %{kind: :custom, text: msg})
            :ok
        end

      :not_found ->
        if msg, do: World.broadcast_room(room_uuid, %{kind: :custom, text: msg})
        :ok

      {:error, _reason} ->
        if msg, do: World.broadcast_room(room_uuid, %{kind: :custom, text: msg})
        :ok
    end
  rescue
    e ->
      Logger.warning("TickBot fire crashed: #{Exception.message(e)}")
      :ok
  end

  ## Tree walk: collect ticking docs

  defp collect_tickers(root_uuid, store) do
    case Schemas.load_dir_schema(root_uuid, store) do
      {:ok, root_schema} ->
        Schema.list_entries(root_schema)
        |> Enum.filter(&(&1.type == :dir))
        |> Enum.flat_map(fn entry -> collect_room_tickers(entry, store) end)

      _ ->
        []
    end
  end

  defp collect_room_tickers(%Schema.Entry{node_id: room_dir_uuid, name: room_name}, store) do
    case Schemas.load_dir_schema(room_dir_uuid, store) do
      {:ok, schema} ->
        room_meta = load_room_meta(room_dir_uuid, store)

        room_ticker =
          if room_meta && room_meta.tick_interval_ms do
            [
              %{
                uuid: room_dir_uuid,
                interval_ms: room_meta.tick_interval_ms,
                message: room_meta.tick_message,
                room_uuid: room_dir_uuid,
                kind: :room,
                name: room_name
              }
            ]
          else
            []
          end

        object_tickers =
          Schema.list_entries(schema)
          |> Enum.filter(fn e -> e.type == :dir and String.ends_with?(e.name, ".obj") end)
          |> Enum.flat_map(fn obj_entry ->
            case Schemas.load_object(obj_entry.node_id, store) do
              {:ok, %Object{tick_interval_ms: ms, tick_message: msg}} when not is_nil(ms) ->
                [
                  %{
                    uuid: obj_entry.node_id,
                    interval_ms: ms,
                    message: msg,
                    room_uuid: room_dir_uuid,
                    kind: :object,
                    name: obj_entry.name
                  }
                ]

              _ ->
                []
            end
          end)

        room_ticker ++ object_tickers

      _ ->
        []
    end
  end

  defp load_room_meta(uuid, store) do
    case Schemas.load_room(uuid, store) do
      {:ok, %Room{} = r} -> r
      _ -> nil
    end
  end
end
