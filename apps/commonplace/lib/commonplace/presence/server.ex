defmodule Commonplace.Presence.Server do
  @moduledoc """
  GenServer managing a single actor's presence.

  Creates the presence document on start, runs a heartbeat loop,
  and cleans up on shutdown. Registers a cold identity that persists
  across restarts.

  The default 10s heartbeat is the actor's liveness assertion cadence. Its
  owner-signed class TTL is the reaper detector window: 30s for interactive
  `.usr`/`.who` actors (three missed assertions) and 120s for service
  `.exe`/`.bot` actors. Tighter defaults would turn ordinary scheduler stalls
  into false expiry.
  """

  use GenServer

  alias Commonplace.Presence
  alias Commonplace.Presence.Identity

  # CX-i9w9 (presence-signing, Model A): `signing_context` + `cert_cids` are
  # the presence-writer's creds — the agent's SigningContext plus its
  # citizenship-minted `{:presence, id}` cert. Threaded into every presence
  # write (create/status/heartbeat/remove) so they land under `:enforce` via
  # the CX-0a9a carve (bound_identity == signer). Absent (anonymous / legacy
  # callers, e.g. a browser tree-view) → `nil`/`[]` reproduces today's
  # best-effort unsigned write (denied under enforce, but non-fatal).
  defstruct [
    :name,
    :type,
    :dir_uuid,
    :store,
    :uuid,
    :identity_uuid,
    :heartbeat_interval,
    :lease_ttl_ms,
    :signing_context,
    cert_cids: []
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def uuid(pid), do: GenServer.call(pid, :uuid)
  def identity_uuid(pid), do: GenServer.call(pid, :identity_uuid)

  @doc """
  Set the `activity` field on this actor's presence doc.

  CX-l5js: threads the server's own `:signing_context` / `:cert_cids`
  (the same creds used for create/status/heartbeat/remove, CX-i9w9) so the
  managed presence path stays signed under `:enforce` — callers no longer
  need to (and cannot) hand-supply creds for a presence doc they don't own.
  """
  def set_activity(pid, activity), do: GenServer.call(pid, {:set_activity, activity})

  @doc """
  Write a batch of optional presence attributes (`:owner` / `:cwd` /
  `:capabilities`) on this actor's presence doc.

  CX-l5js: threads the server's own `:signing_context` / `:cert_cids`, same
  as `set_activity/2`.
  """
  def set_attributes(pid, attrs), do: GenServer.call(pid, {:set_attributes, attrs})

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    type = Keyword.fetch!(opts, :type)
    dir_uuid = Keyword.fetch!(opts, :dir_uuid)
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient)
    interval = Keyword.get(opts, :heartbeat_interval, 10_000)
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, Presence.default_lease_ttl_ms(type))
    signing_context = Keyword.get(opts, :signing_context)
    cert_cids = Keyword.get(opts, :cert_cids, [])

    creds = [
      signing_context: signing_context,
      cert_cids: cert_cids,
      lease_ttl_ms: lease_ttl_ms
    ]

    Process.flag(:trap_exit, true)

    {:ok, uuid} = Presence.create(name, type, dir_uuid, store, creds)
    Presence.update_status(uuid, "running", store, creds)

    # Register cold identity
    {:ok, identity_uuid} = Identity.register(name, type, dir_uuid, store)

    state = %__MODULE__{
      name: name,
      type: type,
      dir_uuid: dir_uuid,
      store: store,
      uuid: uuid,
      identity_uuid: identity_uuid,
      heartbeat_interval: interval,
      lease_ttl_ms: lease_ttl_ms,
      signing_context: signing_context,
      cert_cids: cert_cids
    }

    schedule_heartbeat(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:uuid, _from, state) do
    {:reply, state.uuid, state}
  end

  @impl true
  def handle_call(:identity_uuid, _from, state) do
    {:reply, state.identity_uuid, state}
  end

  @impl true
  def handle_call({:set_activity, activity}, _from, state) do
    result = Presence.set_activity(state.uuid, activity, state.store, creds(state))
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_attributes, attrs}, _from, state) do
    result = Presence.set_attributes(state.uuid, attrs, state.store, creds(state))
    {:reply, result, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    Presence.heartbeat(state.uuid, state.store, creds(state))
    schedule_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # A terminate/2 callback must never crash on an already-stopped
    # dependency. During shutdown (and in tests, where a supervised
    # CommitStore may be torn down while this heartbeat GenServer is still
    # trapping its own exit), the store's GenServer can already be gone —
    # any call into it then raises `{:noproc, …}` / `:noproc`, which would
    # propagate as an abnormal exit and fail the whole run (CX-6hxa: the CI
    # teardown crash, non-zero exit despite green tests). Best-effort the
    # cleanup and swallow a dead-store failure.
    with_live_store(fn ->
      fname = Presence.filename(state.name, state.type)
      Presence.remove(fname, state.dir_uuid, state.store, creds(state))

      # Update cold identity last_seen on shutdown
      Identity.touch_last_seen(state.identity_uuid, state.store)
    end)

    :ok
  end

  # CX-i9w9 — the presence-writer creds threaded into every signed presence
  # write (see the defstruct note).
  defp creds(state) do
    [
      signing_context: state.signing_context,
      cert_cids: state.cert_cids,
      lease_ttl_ms: state.lease_ttl_ms
    ]
  end

  defp with_live_store(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_heartbeat(state) do
    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
  end
end
