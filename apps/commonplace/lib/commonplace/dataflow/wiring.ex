defmodule Commonplace.Dataflow.Wiring do
  @moduledoc """
  Resolves docrefs, manages PubSub subscriptions, and builds edge structs
  for the dataflow graph.

  This module is the bridge between SmartDoc port declarations and the
  runtime PubSub wiring. It does NOT depend on GraphRegistry — the caller
  (Orchestrator) is responsible for passing built edges to GraphRegistry.

  ## Workflow

  1. `resolve_ports/2` — resolve docref strings to UUIDs
  2. `wire/2` — subscribe the calling process to PubSub topics
  3. `build_edges/3` — create edge structs for GraphRegistry
  4. `unwire/1` — unsubscribe when tearing down
  """

  alias Commonplace.Tree.Docref

  @doc """
  Resolve all port docrefs to UUIDs using the given context.

  Takes a `__ports__()` map and a resolution context (keyword list), returns
  `%{docref_string => uuid | nil}` for all ports. Nil values indicate
  unresolvable refs that may be retried later.

  Context options:
  - `:root_uuid` — UUID of the root schema document
  - `:repo_root_uuid` — UUID of the repository root (for `/` prefix)
  - `:tree_root_uuid` — UUID of the tree root (for `!` prefix)
  - `:parent_uuid` — UUID of the parent directory (for `../` prefix)
  - `:ancestors` — list of ancestor UUIDs from parent upward
  - `:loader` — function `(uuid) -> Yelixer.Doc` that loads a schema doc
  """
  @spec resolve_ports(map(), keyword()) :: %{String.t() => String.t() | nil}
  def resolve_ports(%{} = ports, context) when is_list(context) do
    all_refs =
      (Map.get(ports, :blue_inputs, []) ++
         Map.get(ports, :cyan_outputs, []) ++
         Map.get(ports, :red_inputs, []) ++
         Map.get(ports, :magenta_outputs, []))
      |> Enum.uniq()

    Map.new(all_refs, fn ref ->
      case Docref.resolve(ref, context) do
        {:ok, uuid} -> {ref, uuid}
        {:error, _} -> {ref, nil}
      end
    end)
  end

  @doc """
  Subscribe the calling process to PubSub topics for all resolved ports.

  Subscribes to `commits:{uuid}` for blue inputs and cyan outputs
  (cyan implies blue — a process that writes to a doc also needs to
  observe its state). Red inputs also subscribe to `commits:{uuid}`
  since red logs are CRDT documents.

  Returns a subscription info map for use with `unwire/1`.
  """
  @spec wire(map(), map()) :: map()
  def wire(%{} = ports, %{} = resolved) do
    blue_uuids = resolve_refs(Map.get(ports, :blue_inputs, []), resolved)
    cyan_uuids = resolve_refs(Map.get(ports, :cyan_outputs, []), resolved)
    red_uuids = resolve_refs(Map.get(ports, :red_inputs, []), resolved)

    # Cyan implies blue — subscribe to both
    all_blue = Enum.uniq(blue_uuids ++ cyan_uuids)

    Enum.each(all_blue, fn uuid ->
      Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")
    end)

    Enum.each(red_uuids, fn uuid ->
      Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")
    end)

    %{blue_uuids: MapSet.new(all_blue), red_uuids: MapSet.new(red_uuids)}
  end

  @doc """
  Unsubscribe from all PubSub topics previously wired.
  """
  @spec unwire(map()) :: :ok
  def unwire(%{blue_uuids: blue_uuids, red_uuids: red_uuids}) do
    all_uuids = MapSet.union(blue_uuids, red_uuids)

    Enum.each(all_uuids, fn uuid ->
      Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "commits:#{uuid}")
    end)

    :ok
  end

  @doc """
  Build edge structs for GraphRegistry from resolved ports.

  Returns a list of edge maps with `:from`, `:to`, `:color`, and `:process` keys.
  Edges with unresolved (nil) endpoints are filtered out.
  """
  @spec build_edges(String.t(), map(), map()) :: [map()]
  def build_edges(process_name, %{} = ports, %{} = resolved) do
    blue_edges =
      Enum.map(Map.get(ports, :blue_inputs, []), fn ref ->
        %{from: resolved[ref], to: process_name, color: :blue, process: process_name}
      end)

    cyan_edges =
      Enum.map(Map.get(ports, :cyan_outputs, []), fn ref ->
        %{from: process_name, to: resolved[ref], color: :cyan, process: process_name}
      end)

    red_edges =
      Enum.map(Map.get(ports, :red_inputs, []), fn ref ->
        %{from: resolved[ref], to: process_name, color: :red, process: process_name}
      end)

    magenta_edges =
      Enum.map(Map.get(ports, :magenta_outputs, []), fn ref ->
        %{from: process_name, to: resolved[ref], color: :magenta, process: process_name}
      end)

    (blue_edges ++ cyan_edges ++ red_edges ++ magenta_edges)
    |> Enum.reject(fn edge -> is_nil(edge.from) or is_nil(edge.to) end)
  end

  # --- Private ---

  defp resolve_refs(refs, resolved) do
    refs
    |> Enum.map(&Map.get(resolved, &1))
    |> Enum.reject(&is_nil/1)
  end
end
