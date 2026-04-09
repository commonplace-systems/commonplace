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
        render(~s(<view><list><entity kind="x" name="a"/><entity kind="x" name="b"/></list></view>))

      assert html =~ "<ul"
      assert html =~ "<li"
      assert html =~ "a"
      assert html =~ "b"
    end

    test "renders action as an inert button" do
      html =
        render(~s(<view><action name="edit" label="Edit page" description="Open editor"/></view>))

      assert html =~ "<button"
      assert html =~ "btn-disabled"
      assert html =~ "Edit page"
      assert html =~ "Open editor"
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
        render(
          ~s(<view><provenance signer="alice@abc" ts="2026-04-09" commit="c1"/></view>)
        )

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
end
