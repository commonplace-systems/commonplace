defmodule Commonplace.Black.PatternComputeSupervisor do
  @moduledoc """
  CX-o1l9 (Black M1, piece ii): supervisor for
  `Commonplace.Black.PatternCompute` GenServers.

  DynamicSupervisor + ETS key→pid index, modeled directly on
  `Commonplace.Chat.ChatViewComputeSupervisor` (that module's
  `@moduledoc` explains the per-room lazy-start shape this mirrors).
  The key here is caller-supplied (typically `target_uuid`, since a
  `PatternCompute` writes to exactly one target) rather than a chat
  room name — this supervisor is substrate-tier and domain-agnostic,
  unlike its chat-owned sibling.

  ## Lifecycle: lazy, idempotent

  `ensure_started/2` lazy-starts a `PatternCompute` for `key` on first
  call; a second call with the same `key` while one is already running
  returns the existing pid instead of starting a duplicate.
  """

  use DynamicSupervisor

  alias Commonplace.Black.PatternCompute

  @table :black_pattern_compute_index

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_index_table()
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Ensure a `PatternCompute` is running for `key`. `opts` is passed
  straight through to `PatternCompute.start_link/1` (minus `:name`,
  which this supervisor manages) — requires `:root_uuid`, `:pattern`,
  `:target_uuid`, and exactly one of `:compute_fn` / `:code_uuid`.
  """
  def ensure_started(key, opts) when is_list(opts) do
    ensure_index_table()

    case lookup_pid(key) do
      {:ok, pid} ->
        {:ok, pid}

      :none ->
        child_opts = Keyword.put(opts, :name, nil)

        case DynamicSupervisor.start_child(__MODULE__, %{
               id: {:black_pattern_compute, key},
               start: {PatternCompute, :start_link, [child_opts]},
               restart: :temporary
             }) do
          {:ok, pid} ->
            register_pid(key, pid)
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Stop the `PatternCompute` for `key`. No-op if none is running."
  def stop(key) do
    ensure_index_table()

    case lookup_pid(key) do
      {:ok, pid} ->
        unregister(key)
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      :none ->
        :ok
    end
  end

  @doc """
  Test helper: stop all running `PatternCompute` children + clear the
  key→pid table.
  """
  def reset do
    ensure_index_table()

    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        for {_id, child_pid, _type, _modules} <- DynamicSupervisor.which_children(__MODULE__),
            is_pid(child_pid) do
          DynamicSupervisor.terminate_child(__MODULE__, child_pid)
        end
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  # --- Private ---

  defp ensure_index_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @table
    end
  end

  defp lookup_pid(key) do
    case :ets.lookup(@table, key) do
      [{^key, pid}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          unregister(key)
          :none
        end

      [] ->
        :none
    end
  end

  defp register_pid(key, pid) do
    :ets.insert(@table, {key, pid})
    :ok
  end

  defp unregister(key) do
    :ets.delete(@table, key)
    :ok
  end
end
