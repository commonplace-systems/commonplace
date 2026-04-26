defmodule CommonplaceWebWeb.Features.AutoResolutionAnchorTest do
  @moduledoc """
  CX-y0qj (sub-bead ii of CX-8cw5 milestone 1): the canonical
  "auto-resolution lights up" assertion.

  Workspace-claude-equivalent calls invoke_view_action with args = {text}
  ONLY (no messages_uuid / messages_log_uuid / room / author_path).
  Substrate resolves the rest from view_path + session.presence_path.

  Pre-fix: errors with `missing required arg: messages_uuid`.
  Post-fix: dispatch succeeds, message lands, browser sees it,
  author_path resolves to the session's presence_path.

  Tagged `:feature` so plain `mix test` skips it; run with
  `mix test --only feature`.
  """
  use CommonplaceWebWeb.FeatureCase, async: false

  alias Commonplace.Tree.DocBuilder
  alias Commonplace.ViewActionDispatch

  @moduletag :feature

  feature "MCP-style invoke_view_action with args = {text} only — auto-resolution lights up",
          %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    # Workspace-claude-equivalent context: caller knows view_uuid +
    # view_path + the message text + their own session presence path.
    # Args carries ONLY text — substrate resolves the rest.
    context = %{
      view_uuid: room.view_uuid,
      view_path: "chat/general/_view.xml",
      target: nil,
      args: %{"text" => "auto-resolved hello"},
      signer_id: "test-session-agent",
      source: "milestone-1-anchor",
      presence_path: "test-agent.bot"
    }

    # Pre-fix this errors with "missing required arg: messages_uuid".
    # Post-fix it succeeds and returns the standard tree_mutation tuple.
    assert {:ok, :tree_mutation, details} =
             ViewActionDispatch.dispatch("post_message", context)

    assert is_binary(details.message_id)
    assert details.action == "post_message"

    # The message landed in _messages with author_path resolved from
    # session.presence_path (substrate-derived, not caller-supplied).
    {:ok, doc} =
      DocBuilder.reconstruct_snapshot(Commonplace.Store.CommitStoreClient, room.messages_uuid)

    [entry] = Commonplace.Chat.Messages.list(doc)

    assert entry["text"] == "auto-resolved hello"

    assert entry["author_path"] == "test-agent.bot",
           "author_path must come from session.presence_path, not be hardcoded"

    # End-to-end: the browser opening /chat/general renders the
    # substrate-derived message correctly. Cross-cutting demonstration
    # that auto-resolution works WITHOUT changing the human-UI path.
    session
    |> visit("/chat/general")
    |> assert_has(css(".message-text", text: "auto-resolved hello"))
    |> assert_has(Wallaby.Query.text("test-agent.bot"))
    |> take_screenshot(name: "auto_resolution_milestone_1")
  end
end
