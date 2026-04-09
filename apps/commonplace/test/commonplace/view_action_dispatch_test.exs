defmodule Commonplace.ViewActionDispatchTest do
  use ExUnit.Case, async: false

  alias Commonplace.ViewActionDispatch
  alias Commonplace.Dataflow.Magenta

  describe "dispatch/2 audit broadcast" do
    test "broadcasts a magenta event on view_actions topic for every call" do
      Magenta.subscribe("view_actions")

      context = %{
        view_path: "wiki/test",
        view_uuid: "uuid-1",
        target: nil,
        args: %{},
        signer_id: "test@local",
        source: "unit_test"
      }

      _ = ViewActionDispatch.dispatch("history", context)

      assert_receive {:magenta, "view_actions", %Magenta{type: "view_action_invoked"} = msg},
                     1000

      assert msg.source == "unit_test"
      assert msg.payload["action"] == "history"
    end

    test "source defaults to view_action_dispatch when not provided" do
      Magenta.subscribe("view_actions")

      context = %{view_uuid: "uuid-1"}

      _ = ViewActionDispatch.dispatch("edit", context)

      assert_receive {:magenta, "view_actions", %Magenta{source: source}}, 1000
      assert source == "view_action_dispatch"
    end
  end

  describe "dispatch/2 edit" do
    setup do
      Magenta.subscribe("view_actions")
      :ok
    end

    test "edit with a view_uuid returns :ui_transition intent" do
      assert {:ok, :ui_transition, %{action: "edit"}} =
               ViewActionDispatch.dispatch("edit", %{view_uuid: "uuid-1"})
    end

    test "edit without view_uuid errors" do
      assert {:error, reason} = ViewActionDispatch.dispatch("edit", %{view_uuid: nil})
      assert reason =~ "no page loaded"
    end

    test "edit with missing view_uuid key errors" do
      assert {:error, _} = ViewActionDispatch.dispatch("edit", %{})
    end
  end

  describe "dispatch/2 history" do
    setup do
      Magenta.subscribe("view_actions")
      :ok
    end

    test "history always returns :ui_transition intent" do
      assert {:ok, :ui_transition, %{action: "history"}} =
               ViewActionDispatch.dispatch("history", %{view_uuid: "uuid-1"})
    end

    test "history works without a view_uuid (toggles regardless)" do
      assert {:ok, :ui_transition, %{action: "history"}} =
               ViewActionDispatch.dispatch("history", %{})
    end
  end

  describe "dispatch/2 unknown actions" do
    setup do
      Magenta.subscribe("view_actions")
      :ok
    end

    test "unknown action name returns error" do
      assert {:error, reason} = ViewActionDispatch.dispatch("teleport", %{view_uuid: "uuid-1"})
      assert reason =~ "unknown"
    end

    test "non-binary action name returns error" do
      assert {:error, _} = ViewActionDispatch.dispatch(nil, %{view_uuid: "uuid-1"})
    end
  end

  # Note: fork tests would require a live CommandRouter + CommitStore,
  # which is tested in the integration path via the wiki LiveView and
  # MCP tool tests. The unit tests here cover the dispatch + error
  # routing logic.
end
