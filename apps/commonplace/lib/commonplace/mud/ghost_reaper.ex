defmodule Commonplace.MUD.GhostReaper do
  @moduledoc """
  CX-3xwu (A) — the continuous autonomous ghost-reaper. GCs abandoned MUD
  presence `.usr` entries (a crashed/killed session that left a stale presence
  in the tree) so the roster substrate stays clean, not just the `who` display.

  Built to commonplace-plan's safe-design (2026-07-13) with the reap-the-living
  hazard designed OUT at the root, NOT merely bounded:

    * **Keys on LIVE-SESSION membership, NEVER heartbeat.** A `.usr` is reapable
      only if NO live session process backs it. A live-but-slow / idle session
      still has a live process → ALWAYS classified live → NEVER reaped, however
      long since it acted. No staleness signal to race → the load→delayed-
      heartbeat→false-reap FEEDBACK loop cannot exist. (The old
      `Commonplace.Presence.Reaper` keys on heartbeat and is a deliberate no-op;
      this one supersedes it for the MUD roster.)

    * **DEAD-IN-BOTH / union-spares (defense-in-depth for a MUTATING op).** Reap
      a `.usr` ONLY if it is absent from BOTH liveness trackers — spare it if
      EITHER `SessionLimit :live` (authoritative reserve-before-spawn, CX-z0v7 —
      every session kind holds a slot) OR `PresenceRegistry` (the who-filter's
      registration signal) claims it alive. The union is strictly MORE
      conservative than either alone: a registration-failure or a `:live` edge is
      spared. The mutating reaper destroys only what NO signal says is alive —
      deliberately stricter than the read-only who-filter.

      cp-plan #8915: `PresenceRegistry` is no longer PLAYER-session-only.
      `Commonplace.Bots.Dispatcher.register_autonomous_bot/5` ALSO registers
      into it (under the dispatcher's own pid) — a registered autonomous
      bot's mind is alive by definition, whether or not it has ticked
      recently, so its registration counts as membership the exact same way
      a live `PlayerSession`'s does. This needed NO change here: the union
      above already treats `PresenceRegistry` membership as sufficient to
      spare a `.usr`, regardless of who registered it. See that module's
      "Registration IS liveness" moduledoc section for the full mechanism
      (and why it must stay runtime-only, never doc-derived, once CX-5ikm
      makes registration boot-durable).

    * **Per-run FAIL-CLOSED.** Every run builds the live-set fail-closed and
      ABORTS THE WHOLE RUN (reaps nothing) on ANY incompleteness — a tracker
      unavailable, or any live session's filename unreadable. Reaping against a
      partial live-set would false-reap live sessions REPEATEDLY = the persistent
      DoS. Leaving ghosts one more cycle is free; false-reaping a live player is
      not.

    * **Content-discriminator.** Reap only presence-shape entries
      (`{bound_identity, status, type:"usr"}`) by CONTENT; NEVER an identity
      record (`{public_keys, first_seen}` e.g. `jes.usr` @ `__identities__` —
      reaping it destroys the identity registry, the case the B-ii dry-run
      caught); skip anything unclassifiable (fail-closed).

    * **No periodic write anywhere.** There is NO per-session heartbeat/timer
      write (the 2026-07-06 Bursar-flood lesson). The only timer is THIS reaper's
      own bounded reap-cadence; the reader (tree-walk + live-set) does no writes;
      the sole writes are the node-signed `Presence.remove`s, bounded by the
      per-run cap and the (small) dead-set.

    * **Node-signed, value-set-diff scoped, observable, bounded.** A reaper can't
      BE the player → node-elevated `Presence.remove` = `Schema.remove_entry` of
      ONLY that `.usr` (node-as-world-owner GC). Every reap AND every aborted run
      is logged.

  `run_once/1` is the testable core (pure of scheduling) — the pins drive it
  directly; the GenServer just schedules it on a bounded cadence.
  """

  use GenServer
  require Logger

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{PresenceRegistry, SessionLimit, World}
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  @default_interval_ms 300_000
  @default_per_run_cap 64

  defstruct [:store, :root_uuid, :node_ctx, :node_identity, :interval_ms, :per_run_cap]

  # ── lifecycle ──────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = build_state(opts)
    schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = safe_run_once(state)
    schedule_tick(state)
    {:noreply, state}
  end

  # Manual trigger (ops / a supervised one-shot). Returns the run result.
  @impl true
  def handle_call(:run_once, _from, state) do
    {:reply, run_once(state), state}
  end

  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_once)

  defp build_state(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    root_uuid =
      Keyword.get_lazy(opts, :root_uuid, fn ->
        case Commonplace.Workspace.root_uuid() do
          {:ok, r} -> r
          _ -> nil
        end
      end)

    {node_ctx, node_identity} =
      case {NodeIdentity.signing_context(), NodeIdentity.identity()} do
        {{:ok, ctx}, {:ok, id}} -> {ctx, id}
        _ -> {nil, nil}
      end

    %__MODULE__{
      store: store,
      root_uuid: root_uuid,
      node_ctx: node_ctx,
      node_identity: node_identity,
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      per_run_cap: Keyword.get(opts, :per_run_cap, @default_per_run_cap)
    }
  end

  defp schedule_tick(%__MODULE__{interval_ms: ms}), do: Process.send_after(self(), :tick, ms)

  defp safe_run_once(state) do
    run_once(state)
  rescue
    e ->
      Logger.error("GhostReaper: run crashed (reaped nothing): #{inspect(e)}")
      {:aborted, :crashed}
  end

  # ── the testable core ────────────────────────────────────────────────────────

  @doc """
  A single reap run. Builds the live-set fail-closed and, on any incompleteness,
  ABORTS (reaps nothing). Otherwise reaps the dead-in-both presence ghosts
  (content-discriminated, capped, node-signed). Returns `{:ok, reaped_names}` or
  `{:aborted, reason}`.
  """
  def run_once(%__MODULE__{root_uuid: nil}), do: {:aborted, :no_root}
  def run_once(%__MODULE__{node_ctx: nil}), do: {:aborted, :no_node_identity}

  def run_once(%__MODULE__{} = s) do
    case build_live_set(s.store) do
      {:error, reason} ->
        Logger.warning(
          "GhostReaper: ABORTED run (fail-closed, reaped nothing) — #{inspect(reason)}"
        )

        {:aborted, reason}

      {:ok, live_filenames} ->
        ghosts =
          s
          |> all_presence_usr()
          |> Enum.filter(fn g -> reapable?(g, live_filenames) end)
          |> Enum.take(s.per_run_cap)

        reaped =
          for g <- ghosts do
            _ = Presence.remove(g.usr, g.dir, s.store, signing_context: s.node_ctx)

            Logger.info(
              "GhostReaper: reaped ghost .usr=#{g.usr} room=#{inspect(g.room)} " <>
                "bound_identity=#{g.bound_identity} last_hb=#{g.last_hb} why=dead-in-both"
            )

            g.usr
          end

        {:ok, reaped}
    end
  end

  # ── live-set (FAIL-CLOSED union of the two trackers) ─────────────────────────

  @doc """
  The union of live presence_filenames across BOTH liveness trackers
  (`SessionLimit :live` ∪ `PresenceRegistry`). Fail-closed: `{:error, reason}` if
  EITHER tracker is unreadable or any live session's filename can't be resolved —
  the caller then reaps nothing (never reap against a partial live-set).
  """
  def build_live_set(store \\ CommitStoreClient) do
    with {:ok, sl} <- session_limit_filenames(),
         {:ok, reg} <- registry_filenames() do
      _ = store
      {:ok, MapSet.union(sl, reg)}
    end
  end

  # SessionLimit :live pids → each session's presence_filename. Fail-closed:
  # tracker down → :error; ANY live pid's state unreadable → :error (we can't
  # prove the live-set complete, so we must not reap).
  defp session_limit_filenames do
    pids = SessionLimit.live_pids()

    Enum.reduce_while(pids, {:ok, MapSet.new()}, fn pid, {:ok, acc} ->
      case safe_presence_filename(pid) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, fname} -> {:cont, {:ok, MapSet.put(acc, fname)}}
        :error -> {:halt, {:error, {:session_state_unreadable, pid}}}
      end
    end)
  rescue
    e -> {:error, {:session_limit_unavailable, e}}
  catch
    :exit, reason -> {:error, {:session_limit_unavailable, reason}}
  end

  defp safe_presence_filename(pid) do
    case :sys.get_state(pid, 3000) do
      # A binary filename → this live session claims that .usr (add to live-set).
      %{presence_filename: f} when is_binary(f) -> {:ok, f}
      # A live session with no presence file has no .usr to protect → safe skip.
      %{presence_filename: nil} -> {:ok, nil}
      # Any OTHER shape is an unexpected live-session state we can't map → we
      # CANNOT prove which .usr (if any) it backs → fail-closed: abort the run.
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # PresenceRegistry keys (each a presence_filename). Fail-closed: registry not
  # running → :error (an unavailable tracker means we can't build the full union).
  defp registry_filenames do
    if is_pid(Process.whereis(PresenceRegistry)) do
      keys =
        Registry.select(PresenceRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
        |> MapSet.new()

      {:ok, keys}
    else
      {:error, :presence_registry_unavailable}
    end
  rescue
    e -> {:error, {:presence_registry_unavailable, e}}
  end

  # ── candidates + classification ──────────────────────────────────────────────

  # A `.usr` is reapable iff (a) it is a PRESENCE marker by content (not an
  # identity record / unclassifiable), AND (b) DEAD-IN-BOTH: its filename is in
  # NEITHER tracker (spared if the union claims it alive).
  defp reapable?(%{kind: :presence, usr: usr}, live_filenames) do
    not MapSet.member?(live_filenames, usr)
  end

  defp reapable?(_other, _live), do: false

  # Walk the whole tree for `.usr` entries, classifying each by CONTENT.
  defp all_presence_usr(%__MODULE__{store: store, root_uuid: root}) do
    walk_usr(root, "ROOT", store, [])
  end

  defp walk_usr(dir, label, store, acc) do
    Enum.reduce(World.list_entries(dir, store), acc, fn e, acc ->
      cond do
        String.ends_with?(e.name, ".usr") ->
          {kind, meta} = classify(e.node_id, store)

          [
            %{
              usr: e.name,
              room: label,
              dir: dir,
              node_id: e.node_id,
              kind: (label == "__identities__" && :identity) || kind,
              bound_identity: meta && Map.get(meta, "bound_identity"),
              last_hb: meta && Map.get(meta, "heartbeat")
            }
            | acc
          ]

        e.type == :dir ->
          walk_usr(e.node_id, e.name, store, acc)

        true ->
          acc
      end
    end)
  end

  # Content-discriminator (never keyed on name/location): presence-shape
  # (bound_identity + status) is reapable; a public_keys/first_seen identity
  # record is NEVER reapable; anything else is unclassifiable → skip.
  defp classify(uuid, store) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, uuid),
         raw <- ContentType.get_content(doc),
         {:ok, m} <- decode_map(raw) do
      cond do
        Map.has_key?(m, "public_keys") or Map.has_key?(m, "first_seen") -> {:identity, m}
        Map.has_key?(m, "bound_identity") and Map.has_key?(m, "status") -> {:presence, m}
        true -> {:unknown, m}
      end
    else
      _ -> {:unreadable, nil}
    end
  end

  defp decode_map(m) when is_map(m), do: {:ok, m}

  defp decode_map(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> :error
    end
  end

  defp decode_map(_), do: :error
end
