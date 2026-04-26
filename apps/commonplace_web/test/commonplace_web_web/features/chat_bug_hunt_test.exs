defmodule CommonplaceWebWeb.Features.ChatBugHuntTest do
  @moduledoc """
  CX-1si4: bug-hunt feature suite. Free-reign Wallaby exercises against
  the chat MVP. Goal isn't comprehensive coverage — it's surfacing real
  bugs that unit tests + the happy-path feature test miss.

  Each `feature` here probes one likely-buggy surface. When a bug
  surfaces, the test stays as the regression repro and a CX-* bug bead
  is filed.
  """
  use CommonplaceWebWeb.FeatureCase, async: false

  @moduletag :feature

  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Dataflow.RedLog

  # 1. MULTI-TAB CONVERGENCE — the most load-bearing CRDT claim.
  #    Two browser sessions on the same room. One posts, the OTHER
  #    must see it via PubSub re-materialize.
  @sessions 2
  feature "two browsers on the same room see each other's posts live",
          %{sessions: [alice, bob], root: root} do
    {:ok, _room} = Rooms.create(root, "general")

    alice
    |> visit("/chat/general")
    |> assert_has(css("h1", text: "#general"))

    bob
    |> visit("/chat/general")
    |> assert_has(css("h1", text: "#general"))

    # Alice posts. Bob (a separate Wallaby session = separate
    # browser tab = separate LiveView mount) should see it without
    # refreshing.
    alice
    |> fill_in(css("input[name='text']"), with: "alice's message")
    |> click(css("button[type='submit']"))
    |> assert_has(css(".message-text", text: "alice's message"))

    # Bob should see it via PubSub.
    bob |> assert_has(css(".message-text", text: "alice's message"))

    # And vice versa.
    bob
    |> fill_in(css("input[name='text']"), with: "bob's reply")
    |> click(css("button[type='submit']"))
    |> assert_has(css(".message-text", text: "bob's reply"))

    alice |> assert_has(css(".message-text", text: "bob's reply"))

    take_screenshot(alice, name: "multi_tab_alice")
    take_screenshot(bob, name: "multi_tab_bob")
  end

  # 2. RAPID-FIRE POSTING — the same browser submits N messages
  #    back-to-back. Race conditions in YArray append + commit chain?
  feature "rapid-fire 10 posts from one tab all land in order",
          %{session: session, root: root} do
    {:ok, _room} = Rooms.create(root, "general")

    session = visit(session, "/chat/general")

    Enum.each(1..10, fn i ->
      session
      |> fill_in(css("input[name='text']"), with: "rapid-#{i}-end")
      |> click(css("button[type='submit']"))
    end)

    # All 10 must be visible. Using -end suffix so substring-matching
    # doesn't conflate rapid-1 with rapid-10.
    Enum.each(1..10, fn i ->
      assert_has(session, css(".message-text", text: "rapid-#{i}-end"))
    end)

    take_screenshot(session, name: "rapid_fire")
  end

  # 3. CONCURRENT BROWSER + SIMULATED-MCP POSTS — both write to the
  #    same _messages doc concurrently. CRDT merge correctness.
  feature "concurrent browser + MCP posts both land",
          %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    session = visit(session, "/chat/general")

    # Spawn an async task simulating MCP posts during a browser submit
    # cycle. They should interleave at the YArray level via Yelixer's
    # CRDT merge.
    task =
      Task.async(fn ->
        Enum.each(1..5, fn i ->
          Actions.post_message(room.messages_uuid, "mcp-#{i}",
            room: "general",
            signer_id: "commonplace.bot@aaaaaaaa",
            author_path: "commonplace.bot",
            messages_log_uuid: room.log_uuid
          )

          Process.sleep(20)
        end)
      end)

    Enum.each(1..5, fn i ->
      session
      |> fill_in(css("input[name='text']"), with: "browser-#{i}")
      |> click(css("button[type='submit']"))
    end)

    Task.await(task, 5_000)

    # All 10 must be visible (5 from browser + 5 from MCP). If any
    # are lost, that's a CRDT merge regression.
    Enum.each(1..5, fn i ->
      assert_has(session, css(".message-text", text: "mcp-#{i}"))
      assert_has(session, css(".message-text", text: "browser-#{i}"))
    end)

    take_screenshot(session, name: "concurrent")
  end

  # 4. MULTIBYTE / EMOJI / RTL / LONG TEXT round-trip.
  feature "multibyte text round-trips correctly",
          %{session: session, root: root} do
    {:ok, _room} = Rooms.create(root, "general")

    # Note: ChromeDriver's WebDriver protocol is BMP-only — emoji and
    # other supplementary-plane chars can't be typed via Wallaby.
    # Emoji is verified at the data layer instead (see emoji-via-MCP
    # test below).
    cases = [
      {"chinese", "你好世界,这是一个测试"},
      {"arabic_rtl", "مرحبا بالعالم — اختبار"},
      {"combining", "café naïve résumé"},
      {"control_chars", "before tab newline cr"},
      {"long",
       "lorem ipsum dolor sit amet, consectetur adipiscing elit. " <>
         String.duplicate("x", 500)}
    ]

    session = visit(session, "/chat/general")

    Enum.each(cases, fn {label, text} ->
      session
      |> fill_in(css("input[name='text']"), with: text)
      |> click(css("button[type='submit']"))

      # The control_chars case may render with whitespace collapsed
      # by the browser. Check substring instead of full equality.
      probe = String.split(text, ~r/\s+/) |> List.first() |> String.slice(0, 20)

      try do
        assert_has(session, css(".message-text", text: probe))
      rescue
        e ->
          reraise "case #{label}: expected to find #{inspect(probe)} after submitting #{inspect(text)} — #{Exception.message(e)}",
                  __STACKTRACE__
      end
    end)

    take_screenshot(session, name: "multibyte")
  end

  # 5. EMPTY / WHITESPACE composer submits.
  feature "empty and whitespace-only submits don't create messages",
          %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    session = visit(session, "/chat/general")

    # Empty submit (text = "")
    session
    |> fill_in(css("input[name='text']"), with: "")
    |> click(css("button[type='submit']"))

    # Whitespace-only
    session
    |> fill_in(css("input[name='text']"), with: "   ")
    |> click(css("button[type='submit']"))

    # Spaces + newlines
    session
    |> fill_in(css("input[name='text']"), with: "\t\n")
    |> click(css("button[type='submit']"))

    # Brief settle for any stray re-render.
    Process.sleep(200)

    # NO entries should have landed. Verify at the YArray level.
    {:ok, doc} = DocBuilder.reconstruct_snapshot(Commonplace.Store.CommitStoreClient, room.messages_uuid)
    entries = Commonplace.Chat.Messages.list(doc)

    assert entries == [],
           "empty/whitespace-only submits must not create messages, found: #{inspect(entries)}"
  end

  # 6. EDIT FROM MCP → browser observes via PubSub.
  feature "MCP edit lands in browser without refresh",
          %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    {:ok, %{message_id: m1}} =
      Actions.post_message(room.messages_uuid, "v1 from mcp",
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    session
    |> visit("/chat/general")
    |> assert_has(css(".message-text", text: "v1 from mcp"))

    # Edit happens out-of-band (simulating workspace claude calling
    # invoke_view_action with action=edit_message). Browser should
    # see the edit + the (edited) marker.
    {:ok, _} =
      Actions.edit_message(room.messages_uuid, m1, "v2 from mcp edit",
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    session
    |> assert_has(css(".message-text", text: "v2 from mcp edit"))
    |> assert_has(Wallaby.Query.text("(edited)"))

    refute_has(session, css(".message-text", text: "v1 from mcp"))
  end

  # Companion to the multibyte test: emoji at the DATA layer via MCP
  # path (skipping the chromedriver-BMP-only typing limitation).
  feature "emoji round-trip via MCP path renders in browser",
          %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    {:ok, _} =
      Actions.post_message(room.messages_uuid, "🎉🚀💬✨ celebration",
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    session
    |> visit("/chat/general")
    |> assert_has(css(".message-text", text: "🎉🚀💬✨"))
    |> assert_has(css(".message-text", text: "celebration"))

    take_screenshot(session, name: "emoji")
  end

  # 7. DELETE FROM MCP → browser observes [deleted].
  feature "MCP delete lands in browser without refresh",
          %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    {:ok, %{message_id: m1}} =
      Actions.post_message(room.messages_uuid, "secret content",
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    session
    |> visit("/chat/general")
    |> assert_has(css(".message-text", text: "secret content"))

    {:ok, _} =
      Actions.delete_message(room.messages_uuid, m1,
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    session
    |> assert_has(Wallaby.Query.text("[deleted]"))

    refute_has(session, css(".message-text", text: "secret content"))
  end

  # 8. AUTHOR DISPLAY — browser posts attribute to web-user.usr,
  #    MCP posts attribute to commonplace.bot. Both must render
  #    correctly side-by-side.
  feature "browser and MCP author paths render correctly side-by-side",
          %{session: session, root: root} do
    {:ok, room} = Rooms.create(root, "general")

    {:ok, _} =
      Actions.post_message(room.messages_uuid, "I'm an agent",
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    session
    |> visit("/chat/general")
    |> fill_in(css("input[name='text']"), with: "I'm a human")
    |> click(css("button[type='submit']"))

    # Both author paths visible.
    assert_has(session, Wallaby.Query.text("commonplace.bot"))
    assert_has(session, Wallaby.Query.text("web-user.usr"))

    take_screenshot(session, name: "authors")
  end

  # 9. RED ONRAMP — after a post via the dispatcher's MCP path with
  #    messages_log_uuid threaded (CX-1kl1 fix), tail_red on the log
  #    doc should show the post event.
  feature "post via MCP path with log_uuid populates the red onramp",
          %{root: root} do
    {:ok, room} = Rooms.create(root, "general")

    {:ok, _} =
      Actions.post_message(room.messages_uuid, "audit me",
        room: "general",
        signer_id: "commonplace.bot@aaaaaaaa",
        author_path: "commonplace.bot",
        messages_log_uuid: room.log_uuid
      )

    # RedLog onramp's debounce window is 250ms; wait past it.
    Process.sleep(400)

    log = RedLog.load(room.log_uuid)
    events = RedLog.read(log)

    assert Enum.any?(events, fn e ->
             e["type"] == "post" and get_in(e, ["payload", "message_id"]) != nil
           end),
           "post event must reach the red log via the lazy onramp; got events: #{inspect(events)}"
  end
end
