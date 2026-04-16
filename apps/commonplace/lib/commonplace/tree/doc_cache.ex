defmodule Commonplace.Tree.DocCache do
  @moduledoc """
  Read-side cache for reconstructed `Yelixer.Doc` snapshots.

  Keyed on `{uuid, commit_id}`. On `get_snapshot/2`:

  * look up `{:latest, uuid}` in the store
  * if the cached doc's `commit_id` matches, return it (no reconstruction)
  * otherwise call `DocBuilder.reconstruct_snapshot/2` and store the result

  Cache entries are invalidated when a `{:commit, uuid, commit_id, meta}`
  message arrives on the `blue:{uuid}` Phoenix.PubSub topic — the write path
  in `Commonplace.Store.CommitStore` already broadcasts there for every
  commit (see CX-4im). We subscribe lazily per-uuid on first insert and
  unsubscribe when the uuid is evicted or explicitly invalidated.

  Bounded by `max_size` (default 256) with simple LRU eviction based on a
  monotonic access counter.

  Safe to leave un-started: every public function treats a non-running
  server as a pass-through to `DocBuilder.reconstruct_snapshot/2`, so tests
  that don't boot the full `Commonplace.Application` still work.
  """

  use GenServer

  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Store.CommitStoreClient

  @default_max_size 256

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fetch a snapshot doc for `uuid`, consulting the cache first.

  Returns `{:ok, %Yelixer.Doc{}}` or `:none`, the same shape as
  `DocBuilder.reconstruct_snapshot/2`.
  """
  def get_snapshot(store, uuid, name \\ __MODULE__) do
    case lookup(name, uuid) do
      {:ok, commit_id, doc} ->
        # Verify the cached entry is still valid before returning. A
        # legitimately stale entry is possible between the broadcast
        # arriving and us processing it; double-checking the store's
        # :latest pointer is cheap (single GenServer.call).
        case CommitStoreClient.latest_commit(store, uuid) do
          {:ok, %{id: ^commit_id}} ->
            bump_access(name, uuid)
            {:ok, doc}

          {:ok, %{id: new_id} = commit} ->
            # Latest moved since we cached — rebuild and replace.
            reconstruct_and_cache(store, uuid, new_id, commit, name)

          :none ->
            invalidate(name, uuid)
            :none
        end

      :miss ->
        case CommitStoreClient.latest_commit(store, uuid) do
          {:ok, commit} ->
            reconstruct_and_cache(store, uuid, commit.id, commit, name)

          :none ->
            :none
        end
    end
  end

  @doc "Explicitly drop the cached entry for `uuid`. Mostly for tests."
  def invalidate(name \\ __MODULE__, uuid) do
    if running?(name) do
      GenServer.call(name, {:invalidate, uuid})
    else
      :ok
    end
  end

  @doc "Return the current number of cached entries. For tests / introspection."
  def size(name \\ __MODULE__) do
    if running?(name) do
      GenServer.call(name, :size)
    else
      0
    end
  end

  @doc "Return the list of cached uuids in access order (oldest first). For tests."
  def uuids_by_access(name \\ __MODULE__) do
    if running?(name) do
      GenServer.call(name, :uuids_by_access)
    else
      []
    end
  end

  @doc "Clear the cache entirely. For tests."
  def clear(name \\ __MODULE__) do
    if running?(name) do
      GenServer.call(name, :clear)
    else
      :ok
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    name = Keyword.get(opts, :name, __MODULE__)
    # ETS table name = GenServer name. This lets `lookup/2` find the
    # table directly from a cache name without any GenServer round-trip,
    # which is the entire point of the ETS fast path.
    table = ets_table_name(name)

    ^table =
      :ets.new(table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok,
     %{
       table: table,
       max_size: max_size,
       subscribed: MapSet.new(),
       access_counter: 0
     }}
  end

  @impl true
  def handle_call({:put, uuid, commit_id, doc}, _from, state) do
    state = do_put(state, uuid, commit_id, doc)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:invalidate, uuid}, _from, state) do
    state = do_invalidate(state, uuid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:size, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end

  @impl true
  def handle_call(:uuids_by_access, _from, state) do
    uuids =
      :ets.tab2list(state.table)
      |> Enum.sort_by(fn {_uuid, {_cid, _doc, seq}} -> seq end)
      |> Enum.map(fn {uuid, _} -> uuid end)

    {:reply, uuids, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    for uuid <- state.subscribed do
      _ = Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "blue:#{uuid}")
    end

    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | subscribed: MapSet.new(), access_counter: 0}}
  end

  @impl true
  def handle_call({:bump_access, uuid}, _from, state) do
    state =
      case :ets.lookup(state.table, uuid) do
        [{^uuid, {cid, doc, _seq}}] ->
          seq = state.access_counter + 1
          :ets.insert(state.table, {uuid, {cid, doc, seq}})
          %{state | access_counter: seq}

        [] ->
          state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:commit, uuid, _commit_id, _meta}, state) do
    # Invalidate on any commit for this uuid. We rebuild lazily on next
    # get_snapshot rather than eagerly, so workers that never re-read the
    # doc don't pay reconstruction cost.
    state = do_invalidate(state, uuid)
    {:noreply, state}
  end

  # Defensive: Phoenix.PubSub can't deliver other shapes on blue:UUID in
  # this codebase today, but future broadcast shapes would be silently
  # dropped without this clause, which is preferable to crashing the
  # cache process.
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp lookup(name, uuid) do
    case safe_ets_lookup(ets_table_name(name), uuid) do
      [{^uuid, {commit_id, doc, _seq}}] -> {:ok, commit_id, doc}
      _ -> :miss
    end
  end

  defp safe_ets_lookup(table, uuid) do
    try do
      :ets.lookup(table, uuid)
    rescue
      ArgumentError -> []
    end
  end

  defp ets_table_name(name), do: name

  defp reconstruct_and_cache(store, uuid, commit_id, _commit, name) do
    # Use DocBuilder directly — we already have the commit struct path
    # confirmed by the preceding latest_commit call. Calling DocBuilder
    # here keeps the reconstruction logic in one place.
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} = ok ->
        if running?(name) do
          _ = GenServer.call(name, {:put, uuid, commit_id, doc})
        end

        ok

      :none ->
        :none
    end
  end

  defp bump_access(name, uuid) do
    if running?(name) do
      # cast would be simpler, but call keeps ordering deterministic vs
      # concurrent invalidations (the test asserting LRU eviction order
      # would otherwise be racy).
      _ = GenServer.call(name, {:bump_access, uuid})
    end

    :ok
  end

  defp running?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp do_put(state, uuid, commit_id, doc) do
    seq = state.access_counter + 1
    :ets.insert(state.table, {uuid, {commit_id, doc, seq}})

    subscribed =
      if MapSet.member?(state.subscribed, uuid) do
        state.subscribed
      else
        :ok = Phoenix.PubSub.subscribe(Commonplace.PubSub, "blue:#{uuid}")
        MapSet.put(state.subscribed, uuid)
      end

    state = %{state | subscribed: subscribed, access_counter: seq}
    maybe_evict(state)
  end

  defp do_invalidate(state, uuid) do
    case :ets.lookup(state.table, uuid) do
      [{^uuid, _}] ->
        :ets.delete(state.table, uuid)

        subscribed =
          if MapSet.member?(state.subscribed, uuid) do
            _ = Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "blue:#{uuid}")
            MapSet.delete(state.subscribed, uuid)
          else
            state.subscribed
          end

        %{state | subscribed: subscribed}

      [] ->
        state
    end
  end

  defp maybe_evict(state) do
    size = :ets.info(state.table, :size)

    if size > state.max_size do
      # Find the lowest access_seq entry and evict it. We expect O(N) per
      # eviction — fine for N ~ 256; if this cache grows we can switch to
      # an ordered access index, but bd CX-tx8 explicitly says "bounded
      # size" not "fastest possible eviction".
      {victim_uuid, _} =
        :ets.tab2list(state.table)
        |> Enum.min_by(fn {_uuid, {_cid, _doc, seq}} -> seq end)

      do_invalidate(state, victim_uuid)
    else
      state
    end
  end
end
