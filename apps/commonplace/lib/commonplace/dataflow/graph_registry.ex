defmodule Commonplace.Dataflow.GraphRegistry do
  @moduledoc """
  Named GenServer that tracks directed edges between documents for introspection
  and cycle detection.

  Each edge represents a data dependency: `from` document flows into `to` document,
  colored by the channel type (cyan for CRDT sync, red for log, etc.).

  Cyan cycles are the most dangerous — they can cause infinite update loops.
  When add_edges/2 detects a cyan cycle, it logs a warning but does not prevent
  the addition.
  """

  use GenServer
  require Logger

  @type edge :: %{from: String.t(), to: String.t(), color: atom(), process: String.t()}

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @doc """
  Append edges for a process. If adding these edges creates a cyan cycle,
  a warning is logged but the edges are still added.
  """
  @spec add_edges(String.t(), [map()]) :: :ok
  def add_edges(process_name, edges) do
    GenServer.call(__MODULE__, {:add_edges, process_name, edges})
  end

  @doc "Remove all edges belonging to a process."
  @spec remove_edges(String.t()) :: :ok
  def remove_edges(process_name) do
    GenServer.call(__MODULE__, {:remove_edges, process_name})
  end

  @doc "Return all edges in the graph."
  @spec get_graph() :: [edge()]
  def get_graph do
    GenServer.call(__MODULE__, :get_graph)
  end

  @doc "Return list of cycles found via DFS."
  @spec find_cycles() :: [[String.t()]]
  def find_cycles do
    GenServer.call(__MODULE__, :find_cycles)
  end

  @doc "Return processes/edges that read from (depend on) a given uuid."
  @spec dependents(String.t()) :: [edge()]
  def dependents(uuid) do
    GenServer.call(__MODULE__, {:dependents, uuid})
  end

  @doc "Return uuids that the given process reads from."
  @spec dependencies(String.t()) :: [String.t()]
  def dependencies(process_name) do
    GenServer.call(__MODULE__, {:dependencies, process_name})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{edges: []}}
  end

  @impl true
  def handle_call({:add_edges, process_name, new_edges}, _from, state) do
    tagged_edges =
      Enum.map(new_edges, fn edge ->
        Map.put(edge, :process, process_name)
      end)

    updated_edges = state.edges ++ tagged_edges

    # Check for cyan cycles after adding
    cyan_cycles = detect_cycles(updated_edges, :cyan)

    if cyan_cycles != [] do
      Logger.warning(
        "Cyan cycle detected after adding edges for #{process_name}: #{inspect(cyan_cycles)}"
      )
    end

    {:reply, :ok, %{state | edges: updated_edges}}
  end

  def handle_call({:remove_edges, process_name}, _from, state) do
    filtered = Enum.reject(state.edges, fn edge -> edge.process == process_name end)
    {:reply, :ok, %{state | edges: filtered}}
  end

  def handle_call(:get_graph, _from, state) do
    {:reply, state.edges, state}
  end

  def handle_call(:find_cycles, _from, state) do
    # Find cycles across all colors
    colors =
      state.edges
      |> Enum.map(& &1.color)
      |> Enum.uniq()

    all_cycles =
      Enum.flat_map(colors, fn color ->
        detect_cycles(state.edges, color)
      end)

    {:reply, all_cycles, state}
  end

  def handle_call({:dependents, uuid}, _from, state) do
    deps = Enum.filter(state.edges, fn edge -> edge.from == uuid end)
    {:reply, deps, state}
  end

  def handle_call({:dependencies, process_name}, _from, state) do
    uuids =
      state.edges
      |> Enum.filter(fn edge -> edge.process == process_name end)
      |> Enum.map(fn edge -> edge.from end)
      |> Enum.uniq()

    {:reply, uuids, state}
  end

  # --- Cycle Detection ---

  defp detect_cycles(edges, color) do
    adj = build_adjacency(edges, color)
    find_all_cycles(adj)
  end

  defp build_adjacency(edges, color) do
    edges
    |> Enum.filter(fn edge -> edge.color == color end)
    |> Enum.reduce(%{}, fn edge, acc ->
      Map.update(acc, edge.from, [edge.to], fn existing -> [edge.to | existing] end)
    end)
  end

  defp find_all_cycles(adj) do
    nodes = Map.keys(adj)

    {cycles, _visited, _rec_stack} =
      Enum.reduce(nodes, {[], MapSet.new(), MapSet.new()}, fn node,
                                                              {cycles, visited, rec_stack} ->
        if MapSet.member?(visited, node) do
          {cycles, visited, rec_stack}
        else
          dfs(node, adj, visited, rec_stack, [node], cycles)
        end
      end)

    cycles
  end

  defp dfs(node, adj, visited, rec_stack, path, cycles) do
    visited = MapSet.put(visited, node)
    rec_stack = MapSet.put(rec_stack, node)

    neighbors = Map.get(adj, node, [])

    {cycles, visited, rec_stack} =
      Enum.reduce(neighbors, {cycles, visited, rec_stack}, fn neighbor, {cycles_acc, vis, rs} ->
        cond do
          MapSet.member?(rs, neighbor) ->
            # Found a cycle — extract the cycle path from where the neighbor first appears
            cycle_start = Enum.find_index(path, &(&1 == neighbor))

            cycle =
              if cycle_start do
                Enum.slice(path, cycle_start..-1//1)
              else
                [neighbor]
              end

            {[cycle | cycles_acc], vis, rs}

          not MapSet.member?(vis, neighbor) ->
            dfs(neighbor, adj, vis, rs, path ++ [neighbor], cycles_acc)

          true ->
            {cycles_acc, vis, rs}
        end
      end)

    rec_stack = MapSet.delete(rec_stack, node)
    {cycles, visited, rec_stack}
  end
end
