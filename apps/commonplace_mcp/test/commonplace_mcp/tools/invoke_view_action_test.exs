defmodule Commonplace.MCP.Tools.InvokeViewActionTest do
  use ExUnit.Case, async: false

  alias Commonplace.MCP.Tools.InvokeViewAction
  alias Commonplace.Dataflow.Magenta

  @simple_view """
  <view schema="1">
    <entity kind="page" name="Test">
      <body>
        <text format="plain">hello</text>
      </body>
      <action name="edit" label="Edit"/>
      <action name="history" label="History"/>
    </entity>
  </view>
  """

  describe "descriptor/0" do
    test "has the expected name and required fields" do
      desc = InvokeViewAction.descriptor()
      assert desc["name"] == "invoke_view_action"
      assert "view_uuid" in desc["inputSchema"]["required"]
      assert "action" in desc["inputSchema"]["required"]
    end
  end

  describe "run_with_content/4 happy paths" do
    setup do
      Magenta.subscribe("view_actions")
      :ok
    end

    # MCP Response.text/2 encodes the structured payload as a JSON
    # string in the second content block. Decode it for assertions.
    defp structured(result) do
      result["content"]
      |> Enum.at(1)
      |> Map.get("text")
      |> Jason.decode!()
    end

    defp summary(result) do
      result["content"]
      |> Enum.at(0)
      |> Map.get("text")
    end

    test "edit on a view with edit action returns ui_transition" do
      assert {:ok, result} =
               InvokeViewAction.run_with_content(@simple_view, "uuid-1", "edit", %{})

      data = structured(result)
      assert data["class"] == "ui_transition"
      assert data["action"] == "edit"
      assert data["view_uuid"] == "uuid-1"

      assert summary(result) =~ "UI-local"
      assert summary(result) =~ "edit"
    end

    test "history on a view with history action returns ui_transition" do
      assert {:ok, result} =
               InvokeViewAction.run_with_content(@simple_view, "uuid-1", "history", %{})

      data = structured(result)
      assert data["class"] == "ui_transition"
      assert data["action"] == "history"
    end

    test "broadcasts a magenta audit event with source=mcp" do
      _ = InvokeViewAction.run_with_content(@simple_view, "uuid-1", "edit", %{})

      assert_receive {:magenta, "view_actions", %Magenta{type: "view_action_invoked"} = msg},
                     1000

      assert msg.source == "mcp"
      assert msg.payload["action"] == "edit"
      assert msg.payload["view_uuid"] == "uuid-1"
      assert msg.payload["signer_id"] == "mcp-agent@local"
    end
  end

  describe "run_with_content/4 error paths" do
    test "returns error when content is not a view" do
      assert {:error, reason} =
               InvokeViewAction.run_with_content(
                 "# just markdown, not a view",
                 "uuid-1",
                 "edit",
                 %{}
               )

      assert reason =~ "not a view"
    end

    test "returns error when content is malformed XML" do
      assert {:error, reason} =
               InvokeViewAction.run_with_content(
                 "<view><unclosed>",
                 "uuid-1",
                 "edit",
                 %{}
               )

      assert reason =~ "parse error"
    end

    test "returns error when action is not declared in the view" do
      assert {:error, reason} =
               InvokeViewAction.run_with_content(@simple_view, "uuid-1", "teleport", %{})

      assert reason =~ "not declared"
      assert reason =~ "teleport"
      # Error message should list available actions
      assert reason =~ "edit"
      assert reason =~ "history"
    end

    test "lists (none) when the view has no actions" do
      no_actions = ~s(<view><entity kind="page"><body/></entity></view>)

      assert {:error, reason} =
               InvokeViewAction.run_with_content(no_actions, "uuid-1", "edit", %{})

      assert reason =~ "(none)"
    end
  end

  # CX-o3r7 (S2 of CX-p2qp): InvokeViewAction must accept a session
  # context map (run/2 + run_with_content/5) and thread :signing_context
  # into ViewActionDispatch's context. The dispatcher in turn threads it
  # to action handlers; chat actions (V1+) consume it to sign their
  # commits with the SESSION's bound key. Today's handlers (edit, history,
  # fork) don't use it directly, but it must be observable in the audit
  # broadcast (signer_id derived from the SigningContext when present)
  # and present in the dispatcher's context map (verified via the
  # broadcast payload, which currently echoes signer_id).
  describe "session context plumbing (CX-o3r7)" do
    setup do
      Magenta.subscribe("view_actions")
      :ok
    end

    test "audit signer_id is derived from session SigningContext when supplied" do
      {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()

      ctx = %Commonplace.Crypto.SigningContext{
        identity_uuid: "session-agent-7",
        private_key: priv,
        public_key: pub
      }

      _ =
        InvokeViewAction.run_with_content(
          @simple_view,
          "uuid-1",
          "edit",
          %{},
          %{signing_context: ctx}
        )

      expected_signer_id = Commonplace.Crypto.Signing.signer_id("session-agent-7", pub)

      assert_receive {:magenta, "view_actions", %Magenta{type: "view_action_invoked"} = msg},
                     1000

      assert msg.payload["signer_id"] == expected_signer_id,
             "signer_id must be derived from the session SigningContext, " <>
               "got: #{inspect(msg.payload["signer_id"])}"
    end

    test "audit signer_id falls back to mcp-agent@local placeholder when no context" do
      # Existing default-context behavior must be preserved.
      _ = InvokeViewAction.run_with_content(@simple_view, "uuid-1", "edit", %{})

      assert_receive {:magenta, "view_actions", %Magenta{type: "view_action_invoked"} = msg},
                     1000

      assert msg.payload["signer_id"] == "mcp-agent@local"
    end

    test "run/2 accepts a context map and forwards it (no view_uuid happy path needed)" do
      # run/2 is the entry point used by Tools.call when context is
      # available. It MUST forward to run_with_content/5 (or equivalent),
      # passing the context through. We exercise the validation surface
      # here — happy path requires a real view in the commit store.
      assert {:error, :invalid_params, _} = InvokeViewAction.run(%{}, %{})

      assert {:error, :invalid_params, _} =
               InvokeViewAction.run(%{"action" => "edit"}, %{signing_context: :unsigned})
    end
  end

  describe "run/1 validation" do
    test "rejects missing view_uuid" do
      assert {:error, :invalid_params, _} = InvokeViewAction.run(%{"action" => "edit"})
    end

    test "rejects missing action" do
      assert {:error, :invalid_params, _} = InvokeViewAction.run(%{"view_uuid" => "abc"})
    end

    test "rejects empty args" do
      assert {:error, :invalid_params, _} = InvokeViewAction.run(%{})
    end
  end
end
