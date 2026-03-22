defmodule Commonplace.Dataflow.MagentaTest do
  @moduledoc """
  Tests for ephemeral magenta messaging.
  """
  use ExUnit.Case

  alias Commonplace.Dataflow.Magenta

  describe "message envelope" do
    test "creates a message with standard envelope" do
      msg = Magenta.message("restart", "orchestrator", %{pid: "abc"})

      assert msg.type == "restart"
      assert msg.source == "orchestrator"
      assert msg.payload == %{pid: "abc"}
      assert %DateTime{} = msg.timestamp
    end

    test "message is serializable to JSON" do
      msg = Magenta.message("ping", "cli", %{})
      json = Magenta.to_json(msg)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "ping"
      assert decoded["source"] == "cli"
      assert is_binary(decoded["timestamp"])
    end
  end

  describe "send and receive" do
    test "subscriber receives magenta message on matching topic" do
      Magenta.subscribe("workspace/processes/bartleby")

      msg = Magenta.message("restart", "orchestrator", %{reason: "config changed"})
      Magenta.send("workspace/processes/bartleby", msg)

      assert_receive {:magenta, "workspace/processes/bartleby", received_msg}, 1000
      assert received_msg.type == "restart"
      assert received_msg.source == "orchestrator"
      assert received_msg.payload == %{reason: "config changed"}
    end

    test "subscriber does not receive messages on other topics" do
      Magenta.subscribe("workspace/processes/alpha")

      msg = Magenta.message("stop", "cli", %{})
      Magenta.send("workspace/processes/beta", msg)

      refute_receive {:magenta, _, _}, 100
    end

    test "multiple subscribers receive the same message" do
      Magenta.subscribe("workspace/events")

      # Simulate second subscriber in another process
      test_pid = self()

      spawn(fn ->
        Magenta.subscribe("workspace/events")
        send(test_pid, :subscribed)

        receive do
          {:magenta, _, msg} -> send(test_pid, {:other_received, msg.type})
        end
      end)

      receive do
        :subscribed -> :ok
      end

      # Small delay to ensure subscription is active
      Process.sleep(10)

      msg = Magenta.message("notify", "system", %{})
      Magenta.send("workspace/events", msg)

      assert_receive {:magenta, _, received}, 1000
      assert received.type == "notify"

      assert_receive {:other_received, "notify"}, 1000
    end
  end
end
