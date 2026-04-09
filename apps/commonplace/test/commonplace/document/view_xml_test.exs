defmodule Commonplace.Document.ViewXmlTest do
  use ExUnit.Case, async: true

  alias Commonplace.Document.ViewXml
  alias Commonplace.Document.ViewXml.Node

  describe "parse/1" do
    test "parses a minimal view document" do
      assert {:ok, %Node{tag: :view, attrs: %{}, children: []}} =
               ViewXml.parse("<view/>")
    end

    test "parses view with schema attribute" do
      assert {:ok, %Node{tag: :view, attrs: %{"schema" => "1"}}} =
               ViewXml.parse(~s(<view schema="1"/>))
    end

    test "parses a view with nested entity and body" do
      xml = ~s(<view><entity kind="page" name="Home"><body/></entity></view>)

      assert {:ok, %Node{tag: :view, children: [entity]}} = ViewXml.parse(xml)
      assert %Node{tag: :entity, attrs: attrs, children: [body]} = entity
      assert attrs["kind"] == "page"
      assert attrs["name"] == "Home"
      assert %Node{tag: :body} = body
    end

    test "parses text element with format attribute and content" do
      xml = ~s(<view><text format="markdown">hello world</text></view>)

      assert {:ok, %Node{children: [text_node]}} = ViewXml.parse(xml)
      assert %Node{tag: :text, attrs: %{"format" => "markdown"}} = text_node
      assert ViewXml.text_content(text_node) == "hello world"
    end

    test "parses action with multiple attributes" do
      xml =
        ~s(<view><action name="edit" label="Edit" args="text:string" description="Open the editor"/></view>)

      assert {:ok, %Node{children: [action]}} = ViewXml.parse(xml)
      assert action.tag == :action
      assert action.attrs["name"] == "edit"
      assert action.attrs["label"] == "Edit"
      assert action.attrs["args"] == "text:string"
      assert action.attrs["description"] == "Open the editor"
    end

    test "parses field with name and value attributes" do
      xml = ~s(<view><field name="author" value="alice"/></view>)

      assert {:ok, %Node{children: [field]}} = ViewXml.parse(xml)
      assert field.tag == :field
      assert field.attrs["name"] == "author"
      assert field.attrs["value"] == "alice"
    end

    test "parses a list containing multiple entities" do
      xml = ~s(<view><list><entity id="1"/><entity id="2"/><entity id="3"/></list></view>)

      assert {:ok, %Node{children: [list_node]}} = ViewXml.parse(xml)
      assert list_node.tag == :list
      assert length(list_node.children) == 3
      assert Enum.all?(list_node.children, &match?(%Node{tag: :entity}, &1))
    end

    test "parses include element with from and commit attributes" do
      xml =
        ~s(<view><include from="/wiki/foo" commit="abc123"><entity kind="page"/></include></view>)

      assert {:ok, %Node{children: [inc]}} = ViewXml.parse(xml)
      assert inc.tag == :include
      assert inc.attrs["from"] == "/wiki/foo"
      assert inc.attrs["commit"] == "abc123"
      assert [%Node{tag: :entity}] = inc.children
    end

    test "parses provenance element" do
      xml =
        ~s(<view><provenance signer="alice@abc" ts="2026-04-09T00:00:00Z" commit="c1"/></view>)

      assert {:ok, %Node{children: [prov]}} = ViewXml.parse(xml)
      assert prov.tag == :provenance
      assert prov.attrs["signer"] == "alice@abc"
      assert prov.attrs["ts"] == "2026-04-09T00:00:00Z"
    end

    test "parses raw element with target attribute" do
      xml = ~s(<view><raw target="html">&lt;b&gt;hi&lt;/b&gt;</raw></view>)

      assert {:ok, %Node{children: [raw]}} = ViewXml.parse(xml)
      assert raw.tag == :raw
      assert raw.attrs["target"] == "html"
      # Content is the character data (which :xmerl decodes from &lt; etc.)
      assert ViewXml.text_content(raw) =~ "<b>"
    end

    test "handles xml declaration prologue" do
      xml = ~s(<?xml version="1.0" encoding="UTF-8"?>\n<view/>)
      assert {:ok, %Node{tag: :view}} = ViewXml.parse(xml)
    end

    test "strips whitespace-only text between elements" do
      xml = """
      <view>
        <entity kind="page">
          <body/>
        </entity>
      </view>
      """

      assert {:ok, %Node{tag: :view, children: [entity]}} = ViewXml.parse(xml)
      assert [%Node{tag: :body}] = entity.children
    end

    test "preserves non-whitespace text mixed with elements" do
      xml = ~s(<view><text>hello <em>world</em></text></view>)
      assert {:ok, %Node{children: [text_node]}} = ViewXml.parse(xml)
      # text child + <em> (unknown) child
      text = ViewXml.text_content(text_node)
      assert text =~ "hello"
      assert text =~ "world"
    end

    test "unknown vocabulary elements parse as :unknown tag" do
      xml = ~s(<view><mystery foo="bar"/></view>)
      assert {:ok, %Node{children: [mystery]}} = ViewXml.parse(xml)
      assert mystery.tag == :unknown
    end

    test "parses a full worked example covering most of the vocabulary" do
      xml = """
      <view schema="1" signer="alice@4a3f">
        <entity kind="wiki_page" name="Home" id="home">
          <provenance signer="alice@4a3f" ts="2026-04-09T10:00:00Z" commit="abc"/>
          <body>
            <text format="markdown"># Welcome</text>
            <field name="stars" value="42"/>
            <list>
              <entity kind="component" name="yelixer"/>
              <entity kind="component" name="commonplace"/>
            </list>
          </body>
          <action name="edit" label="Edit page"/>
          <action name="history" label="History"/>
        </entity>
      </view>
      """

      assert {:ok, view} = ViewXml.parse(xml)
      assert view.tag == :view
      assert view.attrs["schema"] == "1"
      assert [entity] = view.children
      assert entity.attrs["kind"] == "wiki_page"

      # Spot-check nested structure
      assert Enum.any?(entity.children, &match?(%Node{tag: :provenance}, &1))
      assert Enum.any?(entity.children, &match?(%Node{tag: :body}, &1))
      actions = Enum.filter(entity.children, &match?(%Node{tag: :action}, &1))
      assert length(actions) == 2
    end

    test "returns error on malformed XML" do
      assert {:error, _} = ViewXml.parse("<view><unclosed>")
    end

    test "parses content with non-latin1 unicode (em dash, smart quotes, emoji)" do
      xml =
        ~s(<view><text format="markdown">An em — dash and "smart quotes" plus 🎉</text></view>)

      assert {:ok, %Node{tag: :view, children: [text_node]}} = ViewXml.parse(xml)
      content = ViewXml.text_content(text_node)
      assert content =~ "em"
      assert content =~ "dash"
      assert content =~ "🎉"
    end

    test "returns :not_a_binary for non-binary input" do
      assert ViewXml.parse(nil) == {:error, :not_a_binary}
      assert ViewXml.parse(123) == {:error, :not_a_binary}
    end
  end

  describe "root/1" do
    test "returns the node when it is a view" do
      {:ok, node} = ViewXml.parse("<view/>")
      assert {:ok, ^node} = ViewXml.root(node)
    end

    test "returns :not_a_view for other elements" do
      assert ViewXml.root(%Node{tag: :entity}) == {:error, :not_a_view}
    end
  end

  describe "text_content/1" do
    test "concatenates all text children" do
      {:ok, node} = ViewXml.parse("<view>hello world</view>")
      assert ViewXml.text_content(node) == "hello world"
    end

    test "concatenates text recursively" do
      {:ok, node} = ViewXml.parse("<view>a<entity>b</entity>c</view>")
      assert ViewXml.text_content(node) == "abc"
    end

    test "returns empty string for an empty element" do
      {:ok, node} = ViewXml.parse("<view/>")
      assert ViewXml.text_content(node) == ""
    end
  end
end
