defmodule Commonplace.Scheduler.Agent do
  @moduledoc """
  Userland one-shot scheduler (CX-6av).

  Mounts a CRDT doc at `__system/scheduler` in the workspace root,
  accepts requests on the **magenta** channel (ephemeral fire-and-forget
  pub/sub — see `Commonplace.Dataflow.Channel`) at topic
  `agents/scheduler`, persists every schedule in the doc, and publishes a
  magenta `fire` message on the caller-specified target topic when
  `fire_at` is reached.

  The doc IS the schedule DB — no external persistence. Restart /
  crash recovery reads only the doc; any pending entry whose
  `fire_at` has already passed fires immediately on startup ("missed
  events fire late", catch-up semantic).

  ## Protocol (magenta on `agents/scheduler`)

  Request types the agent accepts:

    - `schedule` payload `%{"fire_at" => iso8601, "target_topic" =>
      binary, "payload" => map, "id" => binary?}` — writes a pending
      entry, arms an internal timer, replies with `scheduled`
      `%{"id" => id}`.
    - `cancel` payload `%{"id" => binary}` — flips status to
      cancelled, clears the timer, replies with `cancelled` or
      `not_found` or `already_fired`.
    - `list` payload `%{}` — replies with `listed`
      `%{"schedules" => [%{"id" => id, ...}, ...]}`.

  Fire emits a magenta `fire` message on the stored target_topic with
  payload = stored payload merged with `%{"id" => schedule_id}`.

  **Replies share the request topic.** Every reply (`scheduled`,
  `cancelled`, `not_found`, `already_fired`, `listed`) is published back
  on `agents/scheduler` — the same topic requests arrive on, *not* a
  per-caller reply topic. So a client subscribes to `agents/scheduler`,
  sends its request there, and must filter by the message `type` to pick
  out its reply (it will also see its own request echoed, and any other
  caller's traffic). The agent is subscribed there too; it ignores any
  magenta message whose `type` it doesn't recognize as a request, which
  is precisely what stops its own replies from looping back as new work.

  ## Multi-peer caveat

  If more than one scheduler agent runs against a synced doc across
  peers, each may broadcast `fire` for the same entry. Subscribers
  would then see duplicates. For P3, run at most one scheduler agent
  per workspace. Leader election is a future bead.

  ## Doc placement

  The scheduler doc lives at `__system/scheduler`. On first start
  the agent lazy-creates both the `__system` directory entry in the
  workspace root and the scheduler doc entry under it. Subsequent
  starts reuse the existing path. Follows the `__`-prefixed
  convention established by `__reflog` / `__bursar.log` / `__merge.log`
  so tree walks that filter system entries stay consistent.
  """

  use GenServer

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Scheduler.Doc, as: SDoc
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{Schema, Walk}
  alias Yelixer.Encoding

  @inbox "agents/scheduler"
  @system_dir "__system"
  @scheduler_entry "scheduler"
  @source "scheduler"

  defmodule State do
    @moduledoc false
    defstruct [:store, :root_uuid, :scheduler_uuid, :now_fn, timers: %{}]
  end

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    now_fn = Keyword.get(opts, :now_fn, &DateTime.utc_now/0)

    scheduler_uuid = ensure_scheduler_doc(store, root_uuid)

    Magenta.subscribe(@inbox)

    state = %State{
      store: store,
      root_uuid: root_uuid,
      scheduler_uuid: scheduler_uuid,
      now_fn: now_fn
    }

    # Catch up: walk pending entries, fire past-due immediately, arm
    # timers for future ones.
    {:ok, schedule_pending(state)}
  end

  # -- incoming magenta --

  @impl true
  def handle_info({:magenta, @inbox, %Magenta{type: "schedule"} = msg}, state) do
    {:noreply, handle_schedule(msg.payload, state)}
  end

  def handle_info({:magenta, @inbox, %Magenta{type: "cancel"} = msg}, state) do
    {:noreply, handle_cancel(msg.payload, state)}
  end

  def handle_info({:magenta, @inbox, %Magenta{type: "list"}}, state) do
    Magenta.send(
      @inbox,
      Magenta.message("listed", @source, %{
        "schedules" => listed_schedules(state)
      })
    )

    {:noreply, state}
  end

  # The agent's own replies land back in the inbox (it subscribed
  # there). Ignore them instead of looping.
  def handle_info({:magenta, @inbox, %Magenta{}}, state), do: {:noreply, state}

  # Fire-due message queued by send_after.
  def handle_info({:fire, id}, state), do: {:noreply, fire(id, state)}

  def handle_info(_other, state), do: {:noreply, state}

  # --- handlers ---

  defp handle_schedule(payload, state) do
    id = Map.get(payload, "id") || UUID.uuid4()
    fire_at = Map.fetch!(payload, "fire_at")
    target_topic = Map.fetch!(payload, "target_topic")
    inner_payload = Map.get(payload, "payload", %{})

    entry = %{
      "fire_at" => fire_at,
      "target_topic" => target_topic,
      "payload" => inner_payload,
      "status" => "pending"
    }

    sdoc = SDoc.load(state.scheduler_uuid, state.store)
    sdoc = SDoc.put(sdoc, id, entry)
    commit(state, sdoc)

    state = arm_timer(state, id, fire_at)

    Magenta.send(@inbox, Magenta.message("scheduled", @source, %{"id" => id}))
    state
  end

  defp handle_cancel(%{"id" => id}, state) do
    sdoc = SDoc.load(state.scheduler_uuid, state.store)

    case SDoc.get(sdoc, id) do
      :error ->
        Magenta.send(@inbox, Magenta.message("not_found", @source, %{"id" => id}))
        state

      {:ok, %{"status" => "fired"}} ->
        Magenta.send(@inbox, Magenta.message("already_fired", @source, %{"id" => id}))
        state

      {:ok, entry} ->
        sdoc = SDoc.put(sdoc, id, Map.put(entry, "status", "cancelled"))
        commit(state, sdoc)
        state = clear_timer(state, id)

        Magenta.send(@inbox, Magenta.message("cancelled", @source, %{"id" => id}))
        state
    end
  end

  defp fire(id, state) do
    sdoc = SDoc.load(state.scheduler_uuid, state.store)

    case SDoc.get(sdoc, id) do
      {:ok, %{"status" => "pending"} = entry} ->
        payload_with_id = Map.put(entry["payload"] || %{}, "id", id)
        Magenta.send(entry["target_topic"], Magenta.message("fire", @source, payload_with_id))

        sdoc = SDoc.put(sdoc, id, Map.put(entry, "status", "fired"))
        commit(state, sdoc)
        clear_timer(state, id)

      _ ->
        # cancelled, already fired, or vanished — no-op.
        clear_timer(state, id)
    end
  end

  # --- helpers ---

  defp ensure_scheduler_doc(store, root_uuid) do
    # Walk existing tree first — no-op commits if already mounted.
    loader = schema_loader(store)

    case Walk.resolve_path(root_uuid, "#{@system_dir}/#{@scheduler_entry}", loader) do
      {:ok, uuid} ->
        uuid

      {:error, _} ->
        system_uuid = ensure_system_dir(store, root_uuid, loader)
        ensure_scheduler_entry(store, system_uuid)
    end
  end

  defp ensure_system_dir(store, root_uuid, loader) do
    root = loader.(root_uuid)

    case Schema.get_entry(root, @system_dir) do
      {:ok, entry} ->
        entry.node_id

      :error ->
        system_uuid = UUID.uuid4()
        system_schema = Schema.new_schema()

        {:ok, _genesis} = CommitStore.ensure_genesis(store, system_uuid)

        CommitStoreClient.create_chained_commit(
          store,
          system_uuid,
          Encoding.encode_update(system_schema)
        )

        updated_root = Schema.add_directory(root, @system_dir, system_uuid)

        CommitStoreClient.create_chained_commit(
          store,
          root_uuid,
          Encoding.encode_update(updated_root)
        )

        system_uuid
    end
  end

  defp ensure_scheduler_entry(store, system_uuid) do
    # Reload after potential mutation in ensure_system_dir.
    system = schema_loader(store).(system_uuid)

    case Schema.get_entry(system, @scheduler_entry) do
      {:ok, entry} ->
        entry.node_id

      :error ->
        scheduler_uuid = UUID.uuid4()
        {:ok, _genesis} = CommitStore.ensure_genesis(store, scheduler_uuid)
        sdoc = SDoc.new(client_id: Commonplace.WriterHand.for_doc(scheduler_uuid))

        CommitStoreClient.create_chained_commit(
          store,
          scheduler_uuid,
          Encoding.encode_update(sdoc)
        )

        updated_system = Schema.add_file(system, @scheduler_entry, scheduler_uuid)

        CommitStoreClient.create_chained_commit(
          store,
          system_uuid,
          Encoding.encode_update(updated_system)
        )

        scheduler_uuid
    end
  end

  # CX-41qg.3: `Schema.new_schema/1` takes the client_id UP FRONT (it
  # mints a "version" item during construction, so patching the struct
  # field afterward — the `Presence.Identity`-style move — would be too
  # late: that item would already be recorded under whatever random
  # client_id `Doc.new/0` picked). This loader backs
  # `ensure_system_dir`/`ensure_scheduler_entry`, which re-commit onto
  # the SAME root/system uuids across scheduler agent (re)starts.
  defp schema_loader(store) do
    fn uuid ->
      client_id = Commonplace.WriterHand.for_doc(uuid)

      case CommitStoreClient.latest_commit(store, uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema(client_id: client_id)
          {:ok, doc} = Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema(client_id: client_id)
      end
    end
  end

  defp commit(state, sdoc) do
    CommitStoreClient.create_chained_commit(
      state.store,
      state.scheduler_uuid,
      Encoding.encode_update(sdoc)
    )
  end

  defp arm_timer(state, id, fire_at_iso) do
    case ms_until(fire_at_iso, state.now_fn) do
      :past ->
        send(self(), {:fire, id})
        state

      {:ok, ms} ->
        ref = Process.send_after(self(), {:fire, id}, ms)
        %{state | timers: Map.put(state.timers, id, ref)}
    end
  end

  defp clear_timer(state, id) do
    case Map.fetch(state.timers, id) do
      {:ok, ref} ->
        Process.cancel_timer(ref)
        %{state | timers: Map.delete(state.timers, id)}

      :error ->
        state
    end
  end

  defp ms_until(fire_at_iso, now_fn) do
    case DateTime.from_iso8601(fire_at_iso) do
      {:ok, fire_at, _} ->
        ms = DateTime.diff(fire_at, now_fn.(), :millisecond)
        if ms <= 0, do: :past, else: {:ok, ms}

      _ ->
        :past
    end
  end

  defp schedule_pending(state) do
    SDoc.load(state.scheduler_uuid, state.store)
    |> SDoc.pending()
    |> Enum.reduce(state, fn {id, entry}, st ->
      arm_timer(st, id, entry["fire_at"])
    end)
  end

  defp listed_schedules(state) do
    SDoc.load(state.scheduler_uuid, state.store)
    |> SDoc.all()
    |> Enum.map(fn {id, entry} -> Map.put(entry, "id", id) end)
  end
end
