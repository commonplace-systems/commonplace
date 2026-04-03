defmodule Commonplace.Cluster.EventHandler do
  @moduledoc """
  Handles cluster membership changes.

  When a new node joins, triggers catch-up sync for all locally-active
  documents with the new peer.
  """

  use GenServer

  alias Commonplace.Sync.NodeSync

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Cluster: node joined — #{node}")

    Task.start(fn ->
      uuids = active_doc_uuids()

      Enum.each(uuids, fn uuid ->
        try do
          {:ok, stats} = NodeSync.catch_up(uuid, node)
          Logger.debug("Catch-up #{uuid} with #{node}: #{inspect(stats)}")
        rescue
          e ->
            Logger.warning("Catch-up #{uuid} with #{node} failed: #{Exception.message(e)}")
        end
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.info("Cluster: node left — #{node}")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp active_doc_uuids do
    Registry.select(Commonplace.Document.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
