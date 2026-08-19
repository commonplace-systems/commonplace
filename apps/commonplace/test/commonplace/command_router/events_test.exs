defmodule Commonplace.CommandRouter.EventsTest do
  @moduledoc """
  Unit tests for the run_command event-wrapping helper. Kept separate from
  command_router_test.exs because it's a pure function test with no GenServer
  state, and we want the failure paths to be exercised without depending on a
  verb that happens to fail.
  """

  use ExUnit.Case, async: false

  alias Commonplace.CommandRouter.Events
  alias Commonplace.Dataflow.Magenta

  @command_topic "__commands"

  setup do
    Magenta.subscribe(@command_topic)
    :ok
  end

  describe "run/3" do
    test "body returning {:ok, value} broadcasts completed and returns {:ok, value}" do
      assert {:ok, 42} =
               Events.run("plain_verb", %{"x" => 1}, fn -> {:ok, 42} end)

      assert_receive {:magenta, @command_topic,
                      %Magenta{type: "command.initiated", payload: init}},
                     500

      assert init["verb"] == "plain_verb"
      assert init["args"] == %{"x" => 1}
      assert is_binary(init["command_id"])

      assert_receive {:magenta, @command_topic,
                      %Magenta{type: "command.completed", payload: done}},
                     500

      assert done["command_id"] == init["command_id"]
      assert done["result"] == 42
      assert is_integer(done["duration_ms"])
    end

    test "body returning {:ok, reply, audit} uses reply in return, audit in event" do
      assert {:ok, "user-visible"} =
               Events.run("split_verb", %{}, fn ->
                 {:ok, "user-visible", %{"detail" => "audit-visible"}}
               end)

      assert_receive {:magenta, @command_topic,
                      %Magenta{type: "command.completed", payload: done}},
                     500

      assert done["result"] == %{"detail" => "audit-visible"}
    end

    test "body returning {:error, reason} broadcasts failed and returns {:error, reason}" do
      assert {:error, :no_ancestor} =
               Events.run("bad_verb", %{"target" => "u1"}, fn -> {:error, :no_ancestor} end)

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.failed", payload: fail}},
                     500

      assert fail["verb"] == "bad_verb"
      assert fail["args"] == %{"target" => "u1"}
      assert fail["reason"] =~ "no_ancestor"
      assert is_integer(fail["duration_ms"])
    end

    test "body that raises is caught, broadcasts failed, returns {:error, reason}" do
      assert {:error, reason} =
               Events.run("boom_verb", %{}, fn -> raise "kaboom" end)

      assert reason =~ "kaboom"

      assert_receive {:magenta, @command_topic, %Magenta{type: "command.failed", payload: fail}},
                     500

      assert fail["verb"] == "boom_verb"
      assert fail["reason"] =~ "kaboom"
    end

    test "command.initiated and command.completed share the same command_id" do
      assert {:ok, :done} = Events.run("correlate_verb", %{}, fn -> {:ok, :done} end)

      assert_receive {:magenta, @command_topic,
                      %Magenta{type: "command.initiated", payload: init}},
                     500

      assert_receive {:magenta, @command_topic,
                      %Magenta{type: "command.completed", payload: done}},
                     500

      assert init["command_id"] == done["command_id"]
    end
  end
end
