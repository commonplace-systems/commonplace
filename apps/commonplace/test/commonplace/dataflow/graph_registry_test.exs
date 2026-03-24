defmodule Commonplace.Dataflow.GraphRegistryTest do
  @moduledoc """
  Tests for GraphRegistry edge tracking and cycle detection.
  """
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Commonplace.Dataflow.GraphRegistry

  setup do
    # Clean slate: remove all edges before each test
    for edge <- GraphRegistry.get_graph() do
      GraphRegistry.remove_edges(edge.process)
    end

    :ok
  end

  describe "add_edges and get_graph" do
    test "add edges and verify get_graph returns them" do
      edges = [
        %{from: "uuid-a", to: "uuid-b", color: :cyan},
        %{from: "uuid-b", to: "uuid-c", color: :red}
      ]

      assert :ok = GraphRegistry.add_edges("proc-1", edges)

      graph = GraphRegistry.get_graph()
      assert length(graph) == 2

      first = Enum.find(graph, &(&1.from == "uuid-a"))
      assert first.to == "uuid-b"
      assert first.color == :cyan
      assert first.process == "proc-1"
    end
  end

  describe "remove_edges" do
    test "add then remove edges, verify empty" do
      edges = [%{from: "uuid-a", to: "uuid-b", color: :cyan}]
      GraphRegistry.add_edges("proc-remove", edges)

      assert length(GraphRegistry.get_graph()) >= 1

      GraphRegistry.remove_edges("proc-remove")

      remaining = GraphRegistry.get_graph()
      assert Enum.all?(remaining, fn e -> e.process != "proc-remove" end)
    end
  end

  describe "find_cycles" do
    test "detects cycle A->B->C->A (all cyan)" do
      GraphRegistry.add_edges("proc-cycle-1", [
        %{from: "A", to: "B", color: :cyan}
      ])

      GraphRegistry.add_edges("proc-cycle-2", [
        %{from: "B", to: "C", color: :cyan}
      ])

      GraphRegistry.add_edges("proc-cycle-3", [
        %{from: "C", to: "A", color: :cyan}
      ])

      cycles = GraphRegistry.find_cycles()
      assert length(cycles) > 0

      # The cycle should contain A, B, and C
      cycle = List.first(cycles)
      assert "A" in cycle
      assert "B" in cycle
      assert "C" in cycle
    end

    test "no false positives for acyclic graph A->B->C" do
      GraphRegistry.add_edges("proc-acyclic", [
        %{from: "A", to: "B", color: :cyan},
        %{from: "B", to: "C", color: :cyan}
      ])

      cycles = GraphRegistry.find_cycles()
      assert cycles == []
    end
  end

  describe "cyan cycle warning" do
    test "logs warning when cyan cycle is created" do
      GraphRegistry.add_edges("proc-warn-1", [
        %{from: "X", to: "Y", color: :cyan}
      ])

      GraphRegistry.add_edges("proc-warn-2", [
        %{from: "Y", to: "Z", color: :cyan}
      ])

      log =
        capture_log(fn ->
          GraphRegistry.add_edges("proc-warn-3", [
            %{from: "Z", to: "X", color: :cyan}
          ])
        end)

      assert log =~ "Cyan cycle detected"
    end
  end

  describe "dependents" do
    test "returns edges that read from a uuid" do
      GraphRegistry.add_edges("proc-dep-1", [
        %{from: "uuid-src", to: "uuid-dst1", color: :cyan}
      ])

      GraphRegistry.add_edges("proc-dep-2", [
        %{from: "uuid-src", to: "uuid-dst2", color: :red}
      ])

      GraphRegistry.add_edges("proc-dep-3", [
        %{from: "uuid-other", to: "uuid-dst3", color: :cyan}
      ])

      deps = GraphRegistry.dependents("uuid-src")
      assert length(deps) == 2
      assert Enum.all?(deps, fn e -> e.from == "uuid-src" end)

      processes = Enum.map(deps, & &1.process) |> Enum.sort()
      assert processes == ["proc-dep-1", "proc-dep-2"]
    end
  end

  describe "dependencies" do
    test "returns uuids that a process reads from" do
      GraphRegistry.add_edges("proc-reader", [
        %{from: "uuid-1", to: "uuid-out", color: :cyan},
        %{from: "uuid-2", to: "uuid-out", color: :cyan},
        %{from: "uuid-1", to: "uuid-out2", color: :red}
      ])

      deps = GraphRegistry.dependencies("proc-reader")
      assert Enum.sort(deps) == ["uuid-1", "uuid-2"]
    end
  end
end
