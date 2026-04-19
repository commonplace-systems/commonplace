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
  alias Commonplace.Workspace

  @default_interval 15_000
  @default_stale_threshold 30_000

  # CX-4wl: `root_uuid` is the *static-override* fallback used by tests
  # that want to pin the reaper to a specific root regardless of
  # `<data_dir>/root`. Production omits this and the reaper re-resolves
  # the workspace root on every scan tick (so `cp checkout` rerooting a
  # long-running node is followed automatically).
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
    root_uuid = Keyword.get(opts, :root_uuid)
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
    case current_root_uuid(state) do
      {:ok, root_uuid} ->
        reaped = reap(root_uuid, state.store, state.stale_threshold)

        if length(reaped) > 0 do
          require Logger

          Logger.info(
            "Presence reaper removed #{length(reaped)} stale entries: #{Enum.join(reaped, ", ")}"
          )
        end

      {:error, _reason} ->
        # No workspace root configured this tick — skip silently and try
        # again next interval. CX-4wl: we don't crash because the root
        # may legitimately be absent during reroot windows.
        :ok
    end

    schedule_scan(state)
    {:noreply, state}
  end

  # CX-4wl: prefer the static override if one was passed at init time
  # (test ergonomics, plus a way to pin the reaper for environments
  # where the workspace root file isn't authoritative). Otherwise read
  # the live workspace root each tick so a CLI-driven reroot is
  # picked up without a restart.
  defp current_root_uuid(%{root_uuid: uuid}) when is_binary(uuid), do: {:ok, uuid}
  defp current_root_uuid(_state), do: Workspace.root_uuid()

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
