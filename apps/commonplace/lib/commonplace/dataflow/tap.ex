defmodule Commonplace.Dataflow.Tap do
  @moduledoc """
  Debug observer for PubSub message flows.

  Subscribe to any topic pattern and log messages for debugging.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def observe(topic) do
    GenServer.call(__MODULE__, {:observe, topic})
  end

  def stop_observing(topic) do
    GenServer.call(__MODULE__, {:stop_observing, topic})
  end

  @impl true
  def init(_opts) do
    {:ok, %{topics: MapSet.new()}}
  end

  @impl true
  def handle_call({:observe, topic}, _from, state) do
    Phoenix.PubSub.subscribe(Commonplace.PubSub, topic)
    {:reply, :ok, %{state | topics: MapSet.put(state.topics, topic)}}
  end

  @impl true
  def handle_call({:stop_observing, topic}, _from, state) do
    Phoenix.PubSub.unsubscribe(Commonplace.PubSub, topic)
    {:reply, :ok, %{state | topics: MapSet.delete(state.topics, topic)}}
  end

  @impl true
  def handle_info({topic, message}, state) do
    Logger.debug("[Tap] #{topic}: #{inspect(message, limit: 200)}")
    {:noreply, state}
  end
end
