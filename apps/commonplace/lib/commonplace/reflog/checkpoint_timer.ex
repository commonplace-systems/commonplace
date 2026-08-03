defmodule Commonplace.Reflog.CheckpointTimer do
  @moduledoc """
  Periodic reflog checkpoint timer.

  Triggers automatic checkpoints at configurable intervals.
  Started by the serve process or supervision tree.
  """

  use GenServer

  alias Commonplace.Reflog.Snapshot

  require Logger

  @default_interval_ms 5 * 60 * 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Trigger an immediate checkpoint."
  def checkpoint_now(server \\ __MODULE__) do
    GenServer.call(server, :checkpoint_now, 30_000)
  end

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient)

    # CX-0t2r (FRESH LINEAGE): CheckpointTimer — and only CheckpointTimer —
    # defaults its owner to "serve" (config :reflog_owner) rather than
    # Commonplace.Reflog.Snapshot's own @default_owner ("server"). This is
    # deliberate: the April-era __reflog/server/ tree carries 3+ months of
    # dormant, UNSIGNED history (CX-0t2r hunt finding) that would be
    # trust-denied under strict+enforce if it ever fired again. Rather than
    # resume writing into that tree, the revived timer builds a fresh
    # __reflog/serve/ lineage under the new node-signed writer below,
    # leaving __reflog/server/ untouched as dead data for eventual GC.
    # checkpoint/3's own default stays "server" for callers/tests that
    # don't pass :owner and expect the historical path.
    owner = Keyword.get(opts, :owner, Application.get_env(:commonplace, :reflog_owner, "serve"))
    interval = Keyword.get(opts, :interval, @default_interval_ms)

    state = %{
      root_uuid: root_uuid,
      store: store,
      owner: owner,
      interval: interval,
      last_checkpoint: nil
    }

    # Schedule first checkpoint
    Process.send_after(self(), :tick, interval)

    {:ok, state}
  end

  @impl true
  def handle_call(:checkpoint_now, _from, state) do
    result = do_checkpoint(state)
    {:reply, result, %{state | last_checkpoint: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(:tick, state) do
    do_checkpoint(state)

    # Schedule next
    Process.send_after(self(), :tick, state.interval)

    {:noreply, %{state | last_checkpoint: DateTime.utc_now()}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp do_checkpoint(state) do
    {:ok, commit_id} = Snapshot.checkpoint(state.root_uuid, state.store, state.owner)
    fp = Base.encode16(commit_id, case: :lower) |> binary_part(0, 12)
    Logger.info("Reflog checkpoint: #{fp}...")
    {:ok, commit_id}
  rescue
    e ->
      Logger.warning("Reflog checkpoint failed: #{inspect(e)}")
      {:error, e}
  end
end
