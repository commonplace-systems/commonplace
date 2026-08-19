defmodule CommonplaceWebWeb.ViewRendererTest do
  use ExUnit.Case, async: true

  alias CommonplaceWebWeb.ViewRenderer

  defp render(xml, path \\ "") do
    {:safe, iodata} = ViewRenderer.render_view(xml, path)
    IO.iodata_to_binary(iodata)
  end

  describe "render_view/2" do
    test "renders a minimal view" do
      html = render("<view/>")
      assert html =~ ~s(class="cp-view)
    end

    test "renders nested entity with kind badge" do
      html = render(~s(<view><entity kind="wiki_page" name="Home"/></view>))
      assert html =~ ~s(class="cp-entity)
      assert html =~ "wiki_page"
      assert html =~ "Home"
    end

    test "renders body container" do
      html = render(~s(<view><entity><body><text>hi</text></body></entity></view>))
      assert html =~ ~s(class="cp-body)
      assert html =~ "hi"
    end

    test "renders text with markdown format as prose container" do
      html = render(~s(<view><text format="markdown"># Hello</text></view>))
      assert html =~ "Hello"
      assert html =~ "<h1"
    end

    test "renders text with code format as pre/code block" do
      html = render(~s{<view><text format="code" language="elixir">IO.puts("hi")</text></view>})
      assert html =~ "<pre"
      assert html =~ "language-elixir"
      # Content should be escaped, not executed
      assert html =~ "IO.puts"
    end

    test "renders plain text as a paragraph" do
      html = render(~s(<view><text>just some text</text></view>))
      assert html =~ "<p"
      assert html =~ "just some text"
    end

    test "renders field as dt/dd pair" do
      html = render(~s(<view><field name="author" value="alice"/></view>))
      assert html =~ "author"
      assert html =~ "alice"
      assert html =~ "<dt"
      assert html =~ "<dd"
    end

    test "renders list as ul with list items" do
      html =
        render(
          ~s(<view><list><entity kind="x" name="a"/><entity kind="x" name="b"/></list></view>)
        )

      assert html =~ "<ul"
      assert html =~ "<li"
      assert html =~ "a"
      assert html =~ "b"
    end

    test "renders action as a clickable phx-click button with action name" do
      html =
        render(~s(<view><action name="edit" label="Edit page" description="Open editor"/></view>))

      assert html =~ "<button"
      assert html =~ ~s(phx-click="view_action")
      assert html =~ ~s(phx-value-action="edit")
      assert html =~ "Edit page"
      assert html =~ "Open editor"
      # No longer disabled — Pass A (CX-vaw) wires dispatch.
      refute html =~ "btn-disabled"
    end

    test "renders action with target attribute as phx-value-target" do
      html =
        render(~s(<view><action name="edit" label="Edit" target="section-1"/></view>))

      assert html =~ ~s(phx-value-action="edit")
      assert html =~ ~s(phx-value-target="section-1")
    end

    test "renders include as a bordered transclusion block" do
      html =
        render(
          ~s(<view><include from="/wiki/arch" commit="abc"><entity kind="sub"/></include></view>)
        )

      assert html =~ "cp-include"
      assert html =~ "transcluded"
      assert html =~ "/wiki/arch"
      assert html =~ "abc"
    end

    test "renders provenance as a byline" do
      html =
        render(~s(<view><provenance signer="alice@abc" ts="2026-04-09" commit="c1"/></view>))

      assert html =~ "cp-provenance"
      assert html =~ "alice@abc"
      assert html =~ "2026-04-09"
      assert html =~ "c1"
    end

    test "renders raw with a warning and escaped content" do
      html = render(~s(<view><raw target="html">&lt;b&gt;hi&lt;/b&gt;</raw></view>))
      assert html =~ "cp-raw"
      assert html =~ "not rendered"
      # Content should be escaped, so the raw < and > appear as entities
      assert html =~ "&lt;b&gt;"
    end

    test "renders wiki links in markdown" do
      html = render(~s(<view><text format="markdown">see [[architecture]]</text></view>))
      assert html =~ "<a href="
      assert html =~ "architecture"
      assert html =~ "/wiki/architecture"
    end

    test "renders bold/italic/code in markdown" do
      html = render(~s(<view><text format="markdown">**bold** *italic* `code`</text></view>))
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ "<code"
      assert html =~ "code"
    end

    test "renders stale indicator when view is stale" do
      html = render(~s(<view stale="true" stale-relative-to="abc123"/>))
      assert html =~ "recomputing"
      assert html =~ "abc123"
    end

    test "shows error block on malformed XML" do
      html = render("<view><unclosed>")
      assert html =~ "View parse error"
    end

    test "shows error block when root is not a view" do
      html = render("<entity/>")
      assert html =~ "Expected a"
      assert html =~ "&lt;view&gt;"
    end

    test "renders a full example with most of the vocabulary" do
      xml = """
      <view schema="1" signer="alice@4a3f">
        <entity kind="wiki_page" name="Home">
          <provenance signer="alice@4a3f" ts="2026-04-09T10:00:00Z"/>
          <body>
            <text format="markdown"># Welcome

            This is a **test** page.</text>
            <list>
              <entity kind="component" name="yelixer">
                <field name="role" value="CRDT port"/>
              </entity>
              <entity kind="component" name="commonplace">
                <field name="role" value="Core store"/>
              </entity>
            </list>
          </body>
          <action name="edit" label="Edit"/>
          <action name="history" label="History"/>
        </entity>
      </view>
      """

      html = render(xml)
      assert html =~ "Welcome"
      assert html =~ "yelixer"
      assert html =~ "commonplace"
      assert html =~ "Core store"
      assert html =~ "Edit"
      assert html =~ "History"
      assert html =~ "alice@4a3f"
      assert html =~ "cp-entity"
      assert html =~ "<h1"
      assert html =~ "<strong>test</strong>"
    end

    test "handles non-view root gracefully" do
      html = render(~s(<entity kind="not-a-view"/>))
      assert html =~ "alert-warning"
    end
  end

  # CX-lok1 (M3 sub-bead iv): two extension paths for the chat view-XML
  # shape — kind-aware CSS classes on <entity>, and phx-submit FORM
  # emission for <action args="..."> declarations.
  describe "render_view/2 — kind-aware entity CSS class (CX-lok1)" do
    test "<entity kind='message'> renders with entity--message class" do
      html = render(~s(<view><entity kind="message" id="m1"/></view>))

      assert html =~ ~s(class="cp-entity entity--message),
             "kind-aware class missing from <entity kind='message'>"
    end

    test "<entity kind='chat_room'> renders with entity--chat_room class" do
      html = render(~s(<view><entity kind="chat_room" name="general"/></view>))
      assert html =~ ~s(entity--chat_room)
      # name still surfaces in the header
      assert html =~ "general"
    end

    test "<entity> with no kind falls back to generic cp-entity" do
      html = render(~s(<view><entity name="x"/></view>))
      assert html =~ "cp-entity"

      refute html =~ "entity--",
             "entity-- modifier should not appear when kind is absent"
    end
  end

  describe "render_view/2 — phx-submit FORM for <action args> (CX-lok1)" do
    test "<action args='text:string'> emits a phx-submit form with one text input" do
      xml = ~s(<view><action name="post_message" label="Send" args="text:string"/></view>)
      html = render(xml)

      assert html =~ ~s(phx-submit="view_action"),
             "args present must emit phx-submit, not phx-click"

      assert html =~ ~s(phx-value-action="post_message")

      assert html =~ ~s(<input type="text" name="text"),
             "arg name='text' must produce <input name='text'>"

      assert html =~ ~s(<button type="submit") or html =~ "type='submit'"
      assert html =~ "Send"
    end

    test "<action args='message_id:string,text:string'> emits two inputs" do
      xml =
        ~s(<view><action name="edit_message" label="Edit" args="message_id:string,text:string"/></view>)

      html = render(xml)

      assert html =~ ~s(name="message_id")
      assert html =~ ~s(name="text")
      assert html =~ ~s(phx-value-action="edit_message")
    end

    test "<action> WITHOUT args still emits a phx-click button (existing behavior)" do
      html = render(~s(<view><action name="edit" label="Edit"/></view>))

      assert html =~ "<button"
      assert html =~ ~s(phx-click="view_action")

      refute html =~ ~s(phx-submit="view_action"),
             "no args means button, not form"
    end

    test "phx-submit form preserves the `target` attr as phx-value-target when present" do
      xml =
        ~s(<view><action name="post" label="X" args="t:string" target="entity-1"/></view>)

      html = render(xml)
      assert html =~ ~s(phx-value-target="entity-1")
    end

    test "the form input has `required` attribute (chat doesn't accept blanks)" do
      xml = ~s(<view><action name="post" label="X" args="text:string"/></view>)
      html = render(xml)
      assert html =~ "required"
    end

    test "non-string types fall back to text input (string-only scope per refinement A)" do
      # Per (iv) confirm-now (A): only :string supported; future types
      # file followups. Test pins this scope so reviewers know it's
      # intentional.
      xml = ~s(<view><action name="post" label="X" args="count:int"/></view>)
      html = render(xml)
      assert html =~ ~s(name="count")
      assert html =~ ~s(type="text"), "non-string types still emit text input for M3"
    end
  end

  describe "render_view/2 — null-tolerant <provenance> (refinement #5 / confirm-now C)" do
    test "renders <provenance signer='X' ts='Y'/> without commit attr" do
      html =
        render(~s(<view><provenance signer="alice@a" ts="2026-04-26T15:25:12Z"/></view>))

      assert html =~ "alice@a"
      assert html =~ "2026-04-26T15:25:12Z"
      refute html =~ "()", "no empty parens for absent commit"
    end

    test "renders <provenance/> with all attrs absent without crashing" do
      html = render("<view><provenance/></view>")
      assert html =~ "cp-provenance"
    end
  end

  describe "render_view/2 — chat-room round-trip (Anchor C support)" do
    test "ChatViewBuilder output renders without crash" do
      messages = [
        %{
          "id" => "msg-1",
          "ts" => "2026-04-26T15:25:12Z",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => "hello room",
          "edited?" => false,
          "deleted?" => false
        }
      ]

      xml = Commonplace.Chat.ChatViewBuilder.build_view_xml(messages, "general")
      html = render(xml, "/chat/general")

      assert html =~ "general"
      assert html =~ "hello room"
      assert html =~ "alice.usr"
      assert html =~ "entity--chat_room"
      assert html =~ "entity--message"
      # Action declarations rendered as phx-submit forms
      assert html =~ ~s(phx-value-action="post_message")
      assert html =~ ~s(phx-value-action="edit_message")
      assert html =~ ~s(phx-value-action="delete_message")
    end
  end
end
