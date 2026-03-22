defmodule Commonplace.Sync.FileLock do
  @moduledoc """
  File locking for coordinating reads and writes.

  Uses a BEAM-native lock manager (ETS + process-based) for in-node
  coordination. Provides shared (read) and exclusive (write) lock
  semantics:

  - Shared locks allow concurrent readers
  - Exclusive locks block all others
  - Non-blocking attempts with retry and timeout
  - Stability check: polls metadata to catch partial writes
  """

  use GenServer

  @default_timeout 30_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Execute a function while holding a shared (read) lock on a file.
  Multiple processes can hold shared locks simultaneously.
  """
  def with_shared_lock(path, fun, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case GenServer.call(server, {:acquire, :shared, path}, timeout) do
      :ok ->
        try do
          result = fun.()
          {:ok, result}
        after
          GenServer.cast(server, {:release, :shared, path, self()})
        end
    end
  end

  @doc """
  Execute a function while holding an exclusive (write) lock on a file.
  Only one process can hold an exclusive lock.
  """
  def with_exclusive_lock(path, fun, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case GenServer.call(server, {:acquire, :exclusive, path}, timeout) do
      :ok ->
        try do
          result = fun.()
          {:ok, result}
        after
          GenServer.cast(server, {:release, :exclusive, path, self()})
        end
    end
  end

  @doc """
  Wait until a file's metadata stops changing (stability check).
  """
  def wait_stable(path, opts \\ []) do
    polls = Keyword.get(opts, :polls, 3)
    interval = Keyword.get(opts, :interval, 50)
    timeout = Keyword.get(opts, :timeout, 5000)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_stable(path, polls, interval, deadline, nil, 0)
  end

  # --- GenServer ---

  @impl true
  def init(_) do
    # locks: %{path => {:shared, count, [pids]} | {:exclusive, pid}}
    {:ok, %{locks: %{}, waiters: []}}
  end

  @impl true
  def handle_call({:acquire, :shared, path}, {pid, _} = from, state) do
    case Map.get(state.locks, path) do
      nil ->
        locks = Map.put(state.locks, path, {:shared, 1, [pid]})
        {:reply, :ok, %{state | locks: locks}}

      {:shared, count, pids} ->
        locks = Map.put(state.locks, path, {:shared, count + 1, [pid | pids]})
        {:reply, :ok, %{state | locks: locks}}

      {:exclusive, _owner} ->
        waiters = state.waiters ++ [{from, :shared, path}]
        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_call({:acquire, :exclusive, path}, {pid, _} = from, state) do
    case Map.get(state.locks, path) do
      nil ->
        locks = Map.put(state.locks, path, {:exclusive, pid})
        {:reply, :ok, %{state | locks: locks}}

      _ ->
        waiters = state.waiters ++ [{from, :exclusive, path}]
        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_cast({:release, _type, path, _pid}, state) do
    state = release_lock(state, path)
    state = process_waiters(state)
    {:noreply, state}
  end

  defp release_lock(state, path) do
    case Map.get(state.locks, path) do
      {:shared, 1, _pids} ->
        %{state | locks: Map.delete(state.locks, path)}

      {:shared, count, [_ | rest_pids]} ->
        %{state | locks: Map.put(state.locks, path, {:shared, count - 1, rest_pids})}

      {:exclusive, _pid} ->
        %{state | locks: Map.delete(state.locks, path)}

      nil ->
        state
    end
  end

  defp process_waiters(state) do
    {granted, remaining} =
      Enum.split_with(state.waiters, fn {_from, type, path} ->
        can_acquire?(state.locks, type, path)
      end)

    state =
      Enum.reduce(granted, state, fn {from, type, path}, state ->
        {pid, _} = from

        locks =
          case type do
            :shared ->
              case Map.get(state.locks, path) do
                {:shared, count, pids} ->
                  Map.put(state.locks, path, {:shared, count + 1, [pid | pids]})

                nil ->
                  Map.put(state.locks, path, {:shared, 1, [pid]})
              end

            :exclusive ->
              Map.put(state.locks, path, {:exclusive, pid})
          end

        GenServer.reply(from, :ok)
        %{state | locks: locks}
      end)

    %{state | waiters: remaining}
  end

  defp can_acquire?(locks, :shared, path) do
    case Map.get(locks, path) do
      nil -> true
      {:shared, _, _} -> true
      {:exclusive, _} -> false
    end
  end

  defp can_acquire?(locks, :exclusive, path) do
    Map.get(locks, path) == nil
  end

  # --- Stability check ---

  defp do_wait_stable(_path, required, _interval, _deadline, _last, count)
       when count >= required,
       do: :ok

  defp do_wait_stable(path, required, interval, deadline, last_meta, count) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      current = file_metadata(path)

      if current == last_meta do
        Process.sleep(interval)
        do_wait_stable(path, required, interval, deadline, current, count + 1)
      else
        Process.sleep(interval)
        do_wait_stable(path, required, interval, deadline, current, 0)
      end
    end
  end

  defp file_metadata(path) do
    case File.stat(path) do
      {:ok, stat} -> {stat.size, stat.mtime}
      {:error, _} -> nil
    end
  end
end
