defmodule Commonplace.Chat.ChatViewComputeSupervisor do
  @moduledoc """
  CX-7kl3 (sub-bead ii of CX-04d8 M3): per-room ViewCompute supervisor.

  DynamicSupervisor + ETS room→pid index mirroring `Chat.OnrampSupervisor`'s
  shape. Owns one `Commonplace.ViewCompute` GenServer per chat room, each
  watching that room's `_messages` doc and writing rendered view-XML to
  the room's `_view.xml` doc.

  ## Critical framing (refinement C)

  This is **chat-owned lifecycle for chat-owned compute_fn** — NOT
  substrate-tier ViewCompute productionization (CX-18s, jes-locked
  answer #2 keeps that OUT of M3). Chat ships its own supervisor for
  the chat compute_fn the same way it ships its own OnrampSupervisor
  for the chat onramp. CX-18s reconciles SmartDoc / Orchestrator /
  __processes.json registration in its own arc, post-M3.

  ## Lifecycle: lazy

  `ensure_started/3` lazy-starts on first call per room. Mirrors the
  OnrampSupervisor pattern. M3 sub-bead (v) wires lazy-start triggers
  into chat-action handlers + room-creation; for now this module is
  callable directly (used by the supervisor test's anchor).
  """

  use DynamicSupervisor

  alias Commonplace.ViewCompute

  @table :chat_view_compute_room_index

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_room_index_table()
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Ensure a ViewCompute is running for `room_name`. Reads source_uuid
  (`_messages`), target_uuid (`_view.xml`), and spec_uuid (`_compute`)
  from opts. The spec_uuid path drives compute via
  `Commonplace.View.ComputeSpec` (M5 sub-bead iv).

  Required opts:
    * `:source_uuid` — the room's `_messages` doc
    * `:target_uuid` — the room's `_view.xml` doc
    * `:spec_uuid` — the room's `_compute` spec doc

  Optional opts:
    * `:store` — CommitStore name (defaults to `CommitStoreClient`)
    * `:router` — CommandRouter (defaults to `Commonplace.CommandRouter`)
  """
  def ensure_started(room_name, opts) when is_binary(room_name) and is_list(opts) do
    ensure_room_index_table()

    case lookup_pid(room_name) do
      {:ok, pid} ->
        {:ok, pid}

      :none ->
        source_uuid = Keyword.fetch!(opts, :source_uuid)
        target_uuid = Keyword.fetch!(opts, :target_uuid)
        # CX-9tj0 (M7 sub-bead iv): :spec_uuid → :code_uuid for the M7
        # ComputeRunner path. Same physical doc UUID; semantics shifted
        # from XML compute-spec to Elixir compute fn source.
        code_uuid = Keyword.fetch!(opts, :spec_uuid)

        child_opts =
          [
            source_uuid: source_uuid,
            target_uuid: target_uuid,
            code_uuid: code_uuid,
            spec_context: %{room_name: room_name},
            name: nil
          ]
          |> maybe_put(:store, Keyword.get(opts, :store))
          |> maybe_put(:router, Keyword.get(opts, :router))

        case DynamicSupervisor.start_child(__MODULE__, %{
               id: {:chat_view_compute, room_name},
               start: {ViewCompute, :start_link, [child_opts]},
               restart: :temporary
             }) do
          {:ok, pid} ->
            register_room_pid(room_name, pid)
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Stop the ViewCompute for `room_name`. No-op if none is running.
  """
  def stop(room_name) when is_binary(room_name) do
    ensure_room_index_table()

    case lookup_pid(room_name) do
      {:ok, pid} ->
        unregister_room(room_name)
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      :none ->
        :ok
    end
  end

  @doc """
  Test helper: stop all running ViewCompute children + clear the
  room→pid table. Mirrors `Chat.OnrampSupervisor.reset/0`.
  """
  def reset do
    ensure_room_index_table()

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

  defp ensure_room_index_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @table
    end
  end

  defp lookup_pid(room_name) do
    case :ets.lookup(@table, room_name) do
      [{^room_name, pid}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          unregister_room(room_name)
          :none
        end

      [] ->
        :none
    end
  end

  defp register_room_pid(room_name, pid) do
    :ets.insert(@table, {room_name, pid})
    :ok
  end

  defp unregister_room(room_name) do
    :ets.delete(@table, room_name)
    :ok
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
