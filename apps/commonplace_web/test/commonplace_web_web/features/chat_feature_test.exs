defmodule CommonplaceWebWeb.Features.ChatFeatureTest do
  @moduledoc """
  CX-xwh4: first end-to-end browser test capability for the project.

  Covers what Phoenix.LiveViewTest can't reach:

    * A real Chrome engine renders ChatRoomLive's HEEX
    * Real DOM events drive the composer form (phx-submit hook)
    * Real LiveSocket connection re-renders on PubSub commit
      delivery — the cross-tab convergence story chat-room.md claims

  Workspace claude's posting path is simulated here via direct
  `Chat.Actions.post_message` calls (the same code MCP's
  invoke_view_action ends up calling). For the live demo, workspace
  posts via MCP and Wallaby's browser session reads the result.

  Tagged `:feature` so plain `mix test` skips it. Run with:

      mix test --only feature

  Requires `bin/setup-browser` to have fetched portable Chrome +
  chromedriver into apps/commonplace_web/priv/browser/.
  """
  use CommonplaceWebWeb.FeatureCase, async: false

  @moduletag :feature

  feature "browser reads + posts to chat room", %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    # Simulate workspace claude posting via MCP. (The same code path
    # invoke_view_action takes; we sidestep MCP transport here for test
    # focus on the browser-driven half of the round trip.)
    {:ok, _} =
      Actions.post_message(room.messages_uuid, "hello from claude (via MCP)",
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    # CX-lok1 (M3 sub-bead iv): selectors updated for the new generic-
    # renderer chat shape. Header is the chat_room entity's <header>;
    # message text lives in <p class="cp-text"> inside an entity--message;
    # composer is an <input name="text"> inside the post_message form.
    session
    |> visit("/chat/general")
    |> assert_has(css(".entity--chat_room"))
    # The post_message FORM is the composer; its visible Send button + text
    # input replace the legacy `<form id="composer">`.
    |> assert_text("Send")
    |> assert_has(css(".cp-text", text: "hello from claude (via MCP)"))
    |> fill_in(css(~s(form[phx-value-action="post_message"] input[name="text"])),
      with: "hello back from the browser"
    )
    |> click(css(~s(form[phx-value-action="post_message"] button[type="submit"])))
    # The phx-submit dispatches → ChatRoomLive handle_event("view_action") →
    # ArgResolver → ViewActionDispatch → Chat.Actions.post_message → commit
    # → ViewCompute recompute → view-XML write → commits PubSub → re-render.
    |> assert_has(css(".cp-text", text: "hello back from the browser"))
    |> take_screenshot(name: "chat_round_trip")
  end
end
