defmodule Commonplace.Presence.Server do
  @moduledoc """
  GenServer managing a single actor's presence.

  Creates the presence document on start, runs a heartbeat loop,
  and cleans up on shutdown. Registers a cold identity that persists
  across restarts.
  """

  use GenServer

  alias Commonplace.Presence
  alias Commonplace.Presence.Identity

  defstruct [:name, :type, :dir_uuid, :store, :uuid, :identity_uuid, :heartbeat_interval]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def uuid(pid), do: GenServer.call(pid, :uuid)
  def identity_uuid(pid), do: GenServer.call(pid, :identity_uuid)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    type = Keyword.fetch!(opts, :type)
    dir_uuid = Keyword.fetch!(opts, :dir_uuid)
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient)
    interval = Keyword.get(opts, :heartbeat_interval, 10_000)

    Process.flag(:trap_exit, true)

    {:ok, uuid} = Presence.create(name, type, dir_uuid, store)
    Presence.update_status(uuid, "running", store)

    # Register cold identity
    {:ok, identity_uuid} = Identity.register(name, type, dir_uuid, store)

    state = %__MODULE__{
      name: name,
      type: type,
      dir_uuid: dir_uuid,
      store: store,
      uuid: uuid,
      identity_uuid: identity_uuid,
      heartbeat_interval: interval
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
  def handle_info(:heartbeat, state) do
    Presence.heartbeat(state.uuid, state.store)
    schedule_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    fname = Presence.filename(state.name, state.type)
    Presence.remove(fname, state.dir_uuid, state.store)

    # Update cold identity last_seen on shutdown
    Identity.touch_last_seen(state.identity_uuid, state.store)
    :ok
  end

  defp schedule_heartbeat(state) do
    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
  end
end
