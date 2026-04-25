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

    session
    |> visit("/chat/general")
    |> assert_has(css("h1", text: "#general"))
    |> assert_has(css(".message-text", text: "hello from claude (via MCP)"))
    |> assert_has(css("#composer"))
    |> fill_in(css("input[name='text']"), with: "hello back from the browser")
    |> click(css("button[type='submit']"))
    # The phx-submit dispatches → Chat.Actions.post_message → CommitStore
    # commit → Phoenix.PubSub on commits:{messages_uuid} → handle_info
    # re-materializes → re-renders. Wallaby waits for the assertion to
    # become true, so an explicit sleep isn't needed.
    |> assert_has(css(".message-text", text: "hello back from the browser"))
    |> take_screenshot(name: "chat_round_trip")
  end
end
