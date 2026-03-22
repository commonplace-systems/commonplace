defmodule Commonplace.Presence.Server do
  @moduledoc """
  GenServer managing a single actor's presence.

  Creates the presence document on start, runs a heartbeat loop,
  and cleans up on shutdown.
  """

  use GenServer

  alias Commonplace.Presence

  defstruct [:name, :type, :dir_uuid, :store, :uuid, :heartbeat_interval]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def uuid(pid), do: GenServer.call(pid, :uuid)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    type = Keyword.fetch!(opts, :type)
    dir_uuid = Keyword.fetch!(opts, :dir_uuid)
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStore)
    interval = Keyword.get(opts, :heartbeat_interval, 10_000)

    Process.flag(:trap_exit, true)

    {:ok, uuid} = Presence.create(name, type, dir_uuid, store)
    Presence.update_status(uuid, "running", store)

    state = %__MODULE__{
      name: name,
      type: type,
      dir_uuid: dir_uuid,
      store: store,
      uuid: uuid,
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
  def handle_info(:heartbeat, state) do
    Presence.heartbeat(state.uuid, state.store)
    schedule_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    fname = Presence.filename(state.name, state.type)
    Presence.remove(fname, state.dir_uuid, state.store)
    :ok
  end

  defp schedule_heartbeat(state) do
    Process.send_after(self(), :heartbeat, state.heartbeat_interval)
  end
end
