defmodule Commonplace.Dataflow.WiringTest do
  use ExUnit.Case

  alias Commonplace.Dataflow.Wiring
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

  describe "resolve_ports/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "wiring_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      store_name = :"commit_store_wiring_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store_name})
      on_exit(fn -> File.rm_rf!(dir) end)

      # Root schema with entries for each port ref
      root_schema =
        Schema.new_schema()
        |> Schema.add_file("config", "uuid-config")
        |> Schema.add_file("output", "uuid-output")
        |> Schema.add_file("events", "uuid-events")
        |> Schema.add_file("alerts", "uuid-alerts")

      commit_schema(store_name, "uuid-root", root_schema)

      loader = &load_schema(store_name, &1)
      context = [root_uuid: "uuid-root", loader: loader]

      %{context: context}
    end

    test "resolves all port docrefs to UUIDs", %{context: context} do
      ports = %{
        blue_inputs: ["config"],
        cyan_outputs: ["output"],
        red_inputs: ["events"],
        magenta_outputs: ["alerts"]
      }

      resolved = Wiring.resolve_ports(ports, context)

      assert resolved["config"] == "uuid-config"
      assert resolved["output"] == "uuid-output"
      assert resolved["events"] == "uuid-events"
      assert resolved["alerts"] == "uuid-alerts"
    end

    test "returns nil for unresolvable refs", %{context: context} do
      ports = %{
        blue_inputs: ["nonexistent"],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = Wiring.resolve_ports(ports, context)

      assert resolved["nonexistent"] == nil
    end

    test "deduplicates refs appearing in multiple port lists", %{context: context} do
      ports = %{
        blue_inputs: ["config"],
        cyan_outputs: ["config"],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = Wiring.resolve_ports(ports, context)

      # Should have exactly one entry for "config"
      assert map_size(resolved) == 1
      assert resolved["config"] == "uuid-config"
    end

    test "handles raw UUID refs" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"

      ports = %{
        blue_inputs: [uuid],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = Wiring.resolve_ports(ports, root_uuid: nil, loader: nil)
      assert resolved[uuid] == uuid
    end
  end

  describe "wire/2" do
    test "subscribes to PubSub for blue inputs" do
      uuid = "wire-blue-#{:rand.uniform(1_000_000)}"

      ports = %{
        blue_inputs: ["config"],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = %{"config" => uuid}

      sub_info = Wiring.wire(ports, resolved)

      assert MapSet.member?(sub_info.blue_uuids, uuid)

      # Verify we actually receive messages on the subscribed topic
      Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{uuid}", {:commit, uuid, "c1", %{}})
      assert_receive {:commit, ^uuid, "c1", %{}}, 500
    end

    test "cyan implies blue subscription" do
      uuid = "wire-cyan-#{:rand.uniform(1_000_000)}"

      ports = %{
        blue_inputs: [],
        cyan_outputs: ["output"],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = %{"output" => uuid}

      sub_info = Wiring.wire(ports, resolved)

      assert MapSet.member?(sub_info.blue_uuids, uuid)

      # Verify we receive commits for the cyan output doc
      Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{uuid}", {:commit, uuid, "c2", %{}})
      assert_receive {:commit, ^uuid, "c2", %{}}, 500
    end

    test "subscribes to PubSub for red inputs" do
      uuid = "wire-red-#{:rand.uniform(1_000_000)}"

      ports = %{
        blue_inputs: [],
        cyan_outputs: [],
        red_inputs: ["events"],
        magenta_outputs: []
      }

      resolved = %{"events" => uuid}

      sub_info = Wiring.wire(ports, resolved)

      assert MapSet.member?(sub_info.red_uuids, uuid)

      Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{uuid}", {:commit, uuid, "c3", %{}})
      assert_receive {:commit, ^uuid, "c3", %{}}, 500
    end

    test "skips unresolved (nil) refs" do
      ports = %{
        blue_inputs: ["missing"],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = %{"missing" => nil}

      sub_info = Wiring.wire(ports, resolved)

      assert MapSet.size(sub_info.blue_uuids) == 0
    end
  end

  describe "unwire/1" do
    test "unsubscribes from all PubSub topics" do
      uuid = "unwire-#{:rand.uniform(1_000_000)}"

      ports = %{
        blue_inputs: ["config"],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = %{"config" => uuid}

      sub_info = Wiring.wire(ports, resolved)

      # Verify subscribed
      Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{uuid}", {:commit, uuid, "c1", %{}})
      assert_receive {:commit, ^uuid, "c1", %{}}, 500

      # Unwire
      assert :ok = Wiring.unwire(sub_info)

      # Verify unsubscribed — should NOT receive
      Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{uuid}", {:commit, uuid, "c2", %{}})
      refute_receive {:commit, ^uuid, "c2", %{}}, 200
    end

    test "unwire handles both blue and red subscriptions" do
      blue_uuid = "unwire-blue-#{:rand.uniform(1_000_000)}"
      red_uuid = "unwire-red-#{:rand.uniform(1_000_000)}"

      ports = %{
        blue_inputs: ["config"],
        cyan_outputs: [],
        red_inputs: ["events"],
        magenta_outputs: []
      }

      resolved = %{"config" => blue_uuid, "events" => red_uuid}

      sub_info = Wiring.wire(ports, resolved)
      assert :ok = Wiring.unwire(sub_info)

      Phoenix.PubSub.broadcast(
        Commonplace.PubSub,
        "commits:#{blue_uuid}",
        {:commit, blue_uuid, "c1", %{}}
      )

      Phoenix.PubSub.broadcast(
        Commonplace.PubSub,
        "commits:#{red_uuid}",
        {:commit, red_uuid, "c2", %{}}
      )

      refute_receive {:commit, _, _, _}, 200
    end
  end

  describe "build_edges/3" do
    test "creates blue input edges (from doc to process)" do
      ports = %{
        blue_inputs: ["config"],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = %{"config" => "uuid-config"}

      edges = Wiring.build_edges("my_process", ports, resolved)

      assert [%{from: "uuid-config", to: "my_process", color: :blue, process: "my_process"}] =
               edges
    end

    test "creates cyan output edges (from process to doc)" do
      ports = %{
        blue_inputs: [],
        cyan_outputs: ["output"],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = %{"output" => "uuid-output"}

      edges = Wiring.build_edges("my_process", ports, resolved)

      assert [%{from: "my_process", to: "uuid-output", color: :cyan, process: "my_process"}] =
               edges
    end

    test "creates red input edges (from doc to process)" do
      ports = %{
        blue_inputs: [],
        cyan_outputs: [],
        red_inputs: ["events"],
        magenta_outputs: []
      }

      resolved = %{"events" => "uuid-events"}

      edges = Wiring.build_edges("my_process", ports, resolved)

      assert [%{from: "uuid-events", to: "my_process", color: :red, process: "my_process"}] =
               edges
    end

    test "creates magenta output edges (from process to doc)" do
      ports = %{
        blue_inputs: [],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: ["alerts"]
      }

      resolved = %{"alerts" => "uuid-alerts"}

      edges = Wiring.build_edges("my_process", ports, resolved)

      assert [%{from: "my_process", to: "uuid-alerts", color: :magenta, process: "my_process"}] =
               edges
    end

    test "filters out edges with unresolved refs" do
      ports = %{
        blue_inputs: ["config", "missing"],
        cyan_outputs: [],
        red_inputs: [],
        magenta_outputs: []
      }

      resolved = %{"config" => "uuid-config", "missing" => nil}

      edges = Wiring.build_edges("my_process", ports, resolved)

      assert length(edges) == 1
      assert hd(edges).from == "uuid-config"
    end

    test "builds all four edge colors together" do
      ports = %{
        blue_inputs: ["config"],
        cyan_outputs: ["output"],
        red_inputs: ["events"],
        magenta_outputs: ["alerts"]
      }

      resolved = %{
        "config" => "uuid-config",
        "output" => "uuid-output",
        "events" => "uuid-events",
        "alerts" => "uuid-alerts"
      }

      edges = Wiring.build_edges("my_process", ports, resolved)

      assert length(edges) == 4

      colors = Enum.map(edges, & &1.color) |> Enum.sort()
      assert colors == [:blue, :cyan, :magenta, :red]
    end
  end

  # --- Helpers ---

  defp commit_schema(store, uuid, doc) do
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp load_schema(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc
  end
end
