defmodule Commonplace.ViewActionDispatchTest do
  use ExUnit.Case, async: false

  alias Commonplace.ViewActionDispatch
  alias Commonplace.Dataflow.Magenta

  # CX-487i (V1+V2 of CX-p2qp): chat post_message clause routes through
  # Commonplace.Chat.Actions.post_message and returns a :tree_mutation
  # intent. args carries messages_uuid + room + author_path + text +
  # optional reply_to. signer_id and signing_context come from session
  # context per the CX-o3r7 plumbing seam.
  describe "dispatch/2 post_message (CX-487i)" do
    setup do
      Magenta.subscribe("view_actions")

      # The chat post_message handler defaults to CommitStoreClient
      # (which routes to the production-named CommitStore started by
      # Application.start in test env). We seed a fresh _messages doc
      # under a random UUID so concurrent tests don't collide.
      messages_uuid = UUID.uuid4()
      doc = Commonplace.Chat.Messages.new()
      update = Yelixer.Encoding.encode_update(doc)
      Commonplace.Store.CommitStore.create_commit(messages_uuid, update, nil)

      %{messages_uuid: messages_uuid}
    end

    test "post_message dispatches to Chat.Actions and returns tree_mutation",
         %{messages_uuid: muuid} do
      # CX-icc2: view_path omitted intentionally — this test exercises
      # dispatcher routing with fully-explicit args (the ChatRoomLive
      # path), not auto-resolution. With view_path absent, the resolver
      # is a no-op and args pass through unchanged.
      context = %{
        view_uuid: "view-uuid-stub",
        args: %{
          "messages_uuid" => muuid,
          "messages_log_uuid" => "log-stub",
          "room" => "general",
          "author_path" => "alice.usr",
          "text" => "hello from dispatcher"
        },
        signer_id: "alice@aaaaaaaa",
        source: "test"
      }

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("post_message", context)

      assert is_binary(details.message_id)
      assert is_binary(details.ts)
      assert details.action == "post_message"

      # The audit broadcast still fires (existing dispatcher contract).
      assert_receive {:magenta, "view_actions",
                      %Magenta{
                        type: "view_action_invoked",
                        payload: %{"action" => "post_message"}
                      }},
                     500
    end

    test "post_message with missing args returns {:error, reason}" do
      assert {:error, _reason} =
               ViewActionDispatch.dispatch("post_message", %{
                 view_uuid: "v",
                 args: %{"text" => "no messages_uuid"}
               })
    end

    test "edit_message dispatches to Chat.Actions and returns tree_mutation",
         %{messages_uuid: muuid} do
      {:ok, %{message_id: m1}} =
        Commonplace.Chat.Actions.post_message(muuid, "v1",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      context = %{
        view_uuid: "view-uuid-stub",
        args: %{
          "messages_uuid" => muuid,
          "room" => "general",
          "author_path" => "alice.usr",
          "message_id" => m1,
          "text" => "v2"
        },
        signer_id: "alice@aaaaaaaa",
        source: "test"
      }

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("edit_message", context)

      assert details.action == "edit_message"
      assert details.edit_of == m1
      assert is_binary(details.message_id)
      refute details.message_id == m1
    end

    # CX-1kl1 regression: dispatcher must thread args["messages_log_uuid"]
    # to Chat.Actions so the lazy red onramp triggers via the MCP path.
    # Pre-fix: dispatcher dropped messages_log_uuid; ensure_room_onramp
    # short-circuited; tail_red on the log doc returned 0 events even
    # after a successful post.
    test "post_message threads args['messages_log_uuid'] to lazy onramp (CX-1kl1)",
         %{messages_uuid: muuid} do
      log_uuid = UUID.uuid4()
      Commonplace.Chat.OnrampSupervisor.reset()

      context = %{
        view_uuid: "v",
        args: %{
          "messages_uuid" => muuid,
          "messages_log_uuid" => log_uuid,
          "room" => "general",
          "author_path" => "alice.usr",
          "text" => "log me"
        },
        signer_id: "alice@aaaaaaaa",
        source: "test"
      }

      assert {:ok, :tree_mutation, _details} =
               ViewActionDispatch.dispatch("post_message", context)

      # The onramp's ETS-tracked room→pid index should now have an entry
      # for "general" — observable proof that the dispatcher threaded
      # messages_log_uuid all the way down to ensure_room_onramp.
      assert :ets.lookup(:chat_onramp_room_index, "general") != [],
             "post_message dispatcher must thread messages_log_uuid → ensure lazy onramp started"
    end

    test "delete_message dispatches to Chat.Actions and returns tree_mutation",
         %{messages_uuid: muuid} do
      {:ok, %{message_id: m1}} =
        Commonplace.Chat.Actions.post_message(muuid, "to be deleted",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      context = %{
        view_uuid: "view-uuid-stub",
        args: %{
          "messages_uuid" => muuid,
          "room" => "general",
          "author_path" => "alice.usr",
          "message_id" => m1
        },
        signer_id: "alice@aaaaaaaa",
        source: "test"
      }

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("delete_message", context)

      assert details.action == "delete_message"
      assert details.tombstone_of == m1
      assert is_binary(details.message_id)
    end
  end

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
