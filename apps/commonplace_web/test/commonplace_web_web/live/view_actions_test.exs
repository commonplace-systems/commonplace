defmodule CommonplaceWebWeb.ViewActionsTest do
  use ExUnit.Case, async: true

  alias CommonplaceWebWeb.ViewActions
  alias Commonplace.Dataflow.Magenta
  alias Phoenix.LiveView.Socket

  # Minimal socket fake — just enough for assign/3 and put_flash/3 which
  # ViewActions calls on UI-local paths. We use the real Phoenix.LiveView.Socket
  # struct with preset assigns so assign/put_flash work as expected.

  defp socket(assigns \\ %{}) do
    %Socket{assigns: Map.merge(%{page_uuid: "uuid-1", show_history: false, __changed__: %{}}, assigns)}
  end

  describe "dispatch/3 audit broadcast" do
    test "broadcasts a magenta event on the view_actions topic for every call" do
      Magenta.subscribe("view_actions")

      context = %{
        view_path: "wiki/about-views",
        view_uuid: "uuid-1",
        target: nil,
        args: %{},
        signer_id: "wiki-user@local",
        source: "wiki_live"
      }

      _ = ViewActions.dispatch("edit", context, socket())

      assert_receive {:magenta, "view_actions", %Magenta{type: "view_action_invoked"} = msg}, 1000
      assert msg.source == "wiki_live"
      assert msg.payload["view_path"] == "wiki/about-views"
      assert msg.payload["action"] == "edit"
      assert msg.payload["signer_id"] == "wiki-user@local"
    end

    test "audit payload includes target and args when present" do
      Magenta.subscribe("view_actions")

      context = %{
        view_path: "wiki/home",
        view_uuid: "uuid-2",
        target: "section-1",
        args: %{"foo" => "bar"},
        signer_id: "alice@abc",
        source: "wiki_live"
      }

      _ = ViewActions.dispatch("edit", context, socket())

      assert_receive {:magenta, "view_actions", %Magenta{} = msg}, 1000
      assert msg.payload["target"] == "section-1"
      assert msg.payload["args"] == %{"foo" => "bar"}
    end
  end

  describe "dispatch/3 UI-local actions" do
    setup do
      # Drain any messages from other tests that subscribed
      Magenta.subscribe("view_actions")
      :ok
    end

    test "edit returns {:ok, socket} with mode=:edit when a page is loaded" do
      assert {:ok, updated} = ViewActions.dispatch("edit", context(), socket())
      assert updated.assigns.mode == :edit
    end

    test "edit errors when no page is loaded" do
      # When there's no page loaded, the real wiki LiveView builds a
      # context with view_uuid=nil (it reads from socket.assigns.page_uuid).
      # The refactored dispatcher rejects edit in that case. Simulate
      # that here by passing a context with view_uuid: nil.
      no_page_context = %{context() | view_uuid: nil}

      assert {:error, reason} =
               ViewActions.dispatch("edit", no_page_context, socket(%{page_uuid: nil}))

      assert reason =~ "no page loaded"
    end

    test "history toggles show_history from false to true" do
      assert {:ok, updated} = ViewActions.dispatch("history", context(), socket())
      assert updated.assigns.show_history == true
    end

    test "history toggles show_history from true to false" do
      assert {:ok, updated} =
               ViewActions.dispatch("history", context(), socket(%{show_history: true}))

      assert updated.assigns.show_history == false
    end
  end

  describe "dispatch/3 unknown actions" do
    test "unknown action name returns {:error, reason}" do
      Magenta.subscribe("view_actions")
      assert {:error, reason} = ViewActions.dispatch("teleport", context(), socket())
      assert reason =~ "unknown"
    end

    test "non-binary action name returns {:error, reason}" do
      Magenta.subscribe("view_actions")
      assert {:error, _} = ViewActions.dispatch(nil, context(), socket())
    end
  end

  defp context do
    %{
      view_path: "wiki/test",
      view_uuid: "uuid-1",
      target: nil,
      args: %{},
      signer_id: "test@local"
    }
  end
end
