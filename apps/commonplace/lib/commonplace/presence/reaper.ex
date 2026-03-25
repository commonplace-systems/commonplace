defmodule Commonplace.Presence.Reaper do
  @moduledoc """
  Periodically scans for presence files with stale heartbeats.

  Removes hot presence entries for crashed processes that didn't clean up.
  A heartbeat is considered stale if it's older than the configured threshold.
  """

  use GenServer

  alias Commonplace.Presence
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStoreClient

  @default_interval 15_000
  @default_stale_threshold 30_000

  defstruct [:root_uuid, :store, :interval, :stale_threshold]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Get the list of stale presence entries without removing them."
  def find_stale(root_uuid, store \\ CommitStoreClient, stale_threshold \\ @default_stale_threshold) do
    root_doc = load_schema(root_uuid, store)
    presence_entries = Presence.discover(root_doc, :all)
    now = DateTime.utc_now()

    Enum.filter(presence_entries, fn entry ->
      case Presence.read(entry.node_id, store) do
        %{"heartbeat" => heartbeat} ->
          case DateTime.from_iso8601(heartbeat) do
            {:ok, hb_time, _} ->
              age_ms = DateTime.diff(now, hb_time, :millisecond)
              age_ms > stale_threshold

            _ ->
              true
          end

        _ ->
          false
      end
    end)
  end

  @doc "Reap stale presence entries. Returns list of removed entry names."
  def reap(root_uuid, store \\ CommitStoreClient, stale_threshold \\ @default_stale_threshold) do
    stale = find_stale(root_uuid, store, stale_threshold)

    Enum.map(stale, fn entry ->
      Presence.remove(entry.name, root_uuid, store)
      entry.name
    end)
  end

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.get(opts, :store, CommitStoreClient)
    interval = Keyword.get(opts, :interval, @default_interval)
    stale_threshold = Keyword.get(opts, :stale_threshold, @default_stale_threshold)

    state = %__MODULE__{
      root_uuid: root_uuid,
      store: store,
      interval: interval,
      stale_threshold: stale_threshold
    }

    schedule_scan(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    reaped = reap(state.root_uuid, state.store, state.stale_threshold)

    if length(reaped) > 0 do
      require Logger
      Logger.info("Presence reaper removed #{length(reaped)} stale entries: #{Enum.join(reaped, ", ")}")
    end

    schedule_scan(state)
    {:noreply, state}
  end

  defp schedule_scan(state) do
    Process.send_after(self(), :scan, state.interval)
  end

  defp load_schema(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
