defmodule Commonplace.Chat.ChatViewBuilderTest do
  @moduledoc """
  CX-7kl3 (sub-bead ii of CX-04d8 M3): tests for the chat-tier
  view-XML builder. Takes materialized message entries (as produced
  by `Commonplace.Materialize.materialize/2` in M2) + room name
  and emits view-XML matching the held shape from the M3 spec §3.

  ChatViewBuilder is chat-tier, NOT substrate. Future view kinds get
  their own builders; this is just the chat one.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Chat.ChatViewBuilder
  alias Commonplace.Document.ViewXml

  defp parse(xml), do: ViewXml.parse(xml)

  describe "build_view_xml/2 — top-level shape" do
    test "produces a <view> with the chat_room entity + action declarations" do
      xml = ChatViewBuilder.build_view_xml([], "general")
      assert {:ok, %ViewXml.Node{tag: :view} = view} = parse(xml)

      [room | actions] =
        view.children
        |> Enum.filter(&match?(%ViewXml.Node{}, &1))

      assert room.tag == :entity
      assert room.attrs["kind"] == "chat_room"
      assert room.attrs["name"] == "general"
      assert room.attrs["id"] == "general"

      action_names =
        actions
        |> Enum.map(& &1.attrs["name"])

      assert "post_message" in action_names
      assert "edit_message" in action_names
      assert "delete_message" in action_names
    end

    test "actions carry <arg from='...'/> children for substrate ArgResolver" do
      xml = ChatViewBuilder.build_view_xml([], "general")
      {:ok, view} = parse(xml)

      post = find_action(view, "post_message")

      args = post.children |> Enum.filter(&match?(%ViewXml.Node{tag: :arg}, &1))

      bys = Enum.map(args, & &1.attrs["from"])
      assert "../_messages" in bys
      assert "../_messages.log" in bys
      assert ".." in bys
      assert "$session.presence_path" in bys
    end

    test "empty room: <list id='messages'> exists but has no entity children" do
      xml = ChatViewBuilder.build_view_xml([], "general")
      {:ok, view} = parse(xml)

      list = find_messages_list(view)
      message_entities = Enum.filter(list.children, &match?(%ViewXml.Node{tag: :entity}, &1))

      assert message_entities == [], "empty list should have no message entities"
    end
  end

  describe "build_view_xml/2 — single message" do
    test "renders an entity with provenance, fields, and text body" do
      messages = [
        %{
          "id" => "msg-1",
          "ts" => "2026-04-26T15:25:12Z",
          "author_signer_id" => "alice@9c8d7e6f",
          "author_path" => "alice.usr",
          "text" => "Hello, room.",
          "edited?" => false,
          "deleted?" => false
        }
      ]

      xml = ChatViewBuilder.build_view_xml(messages, "general")
      {:ok, view} = parse(xml)

      [msg] = list_messages(view)

      assert msg.attrs["kind"] == "message"
      assert msg.attrs["id"] == "msg-1"

      prov = find_child(msg, :provenance)
      assert prov.attrs["signer"] == "alice@9c8d7e6f"
      assert prov.attrs["ts"] == "2026-04-26T15:25:12Z"

      refute Map.has_key?(prov.attrs, "commit"),
             "commit attr deferred per refinement #5"

      assert field_value(msg, "author_path") == "alice.usr"
      assert field_value(msg, "edited") == "false"
      assert field_value(msg, "deleted") == "false"

      body = find_child(msg, :body)
      [text] = body.children |> Enum.filter(&match?(%ViewXml.Node{tag: :text}, &1))
      assert text.attrs["format"] == "plain"
      assert ViewXml.text_content(text) == "Hello, room."
    end
  end

  describe "build_view_xml/2 — edit-state encoding" do
    test "edited message: edited=true, edited_at field, body text is chain-tip's text" do
      messages = [
        %{
          "id" => "msg-2",
          "ts" => "2026-04-26T15:26:33Z",
          "author_signer_id" => "bob@2e3f4a5b",
          "author_path" => "bob.usr",
          "text" => "Hi Alice — corrected.",
          "edited?" => true,
          "edited_at" => "2026-04-26T15:27:01Z",
          "deleted?" => false
        }
      ]

      xml = ChatViewBuilder.build_view_xml(messages, "general")
      {:ok, view} = parse(xml)

      [msg] = list_messages(view)

      assert field_value(msg, "edited") == "true"
      assert field_value(msg, "edited_at") == "2026-04-26T15:27:01Z"

      body = find_child(msg, :body)
      [text] = body.children |> Enum.filter(&match?(%ViewXml.Node{tag: :text}, &1))
      assert ViewXml.text_content(text) == "Hi Alice — corrected."
    end
  end

  describe "build_view_xml/2 — delete-state encoding" do
    test "deleted message: deleted=true, body text is [deleted] (English literal per refinement)" do
      messages = [
        %{
          "id" => "msg-3",
          "ts" => "2026-04-26T15:28:00Z",
          "author_signer_id" => "alice@9c8d7e6f",
          "author_path" => "alice.usr",
          "text" => "this should not surface",
          "edited?" => false,
          "deleted?" => true
        }
      ]

      xml = ChatViewBuilder.build_view_xml(messages, "general")
      {:ok, view} = parse(xml)

      [msg] = list_messages(view)

      assert field_value(msg, "deleted") == "true"

      body = find_child(msg, :body)
      [text] = body.children |> Enum.filter(&match?(%ViewXml.Node{tag: :text}, &1))

      assert ViewXml.text_content(text) == "[deleted]",
             "deleted body must show [deleted], not original text"
    end
  end

  describe "build_view_xml/2 — reply_to encoding" do
    test "reply_to present: emits <field name='reply_to' value='msg-1'/>" do
      messages = [
        %{
          "id" => "msg-2",
          "ts" => "2026-04-26T15:25:12Z",
          "author_signer_id" => "bob@x",
          "author_path" => "bob.usr",
          "text" => "Replying to alice",
          "reply_to" => "msg-1",
          "edited?" => false,
          "deleted?" => false
        }
      ]

      xml = ChatViewBuilder.build_view_xml(messages, "general")
      {:ok, view} = parse(xml)

      [msg] = list_messages(view)
      assert field_value(msg, "reply_to") == "msg-1"
    end

    test "reply_to absent: omitted" do
      messages = [
        %{
          "id" => "msg-1",
          "ts" => "2026-04-26T15:25:12Z",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => "Standalone",
          "edited?" => false,
          "deleted?" => false
        }
      ]

      xml = ChatViewBuilder.build_view_xml(messages, "general")
      {:ok, view} = parse(xml)

      [msg] = list_messages(view)

      reply_field =
        msg.children
        |> Enum.find(fn
          %ViewXml.Node{tag: :field, attrs: %{"name" => "reply_to"}} -> true
          _ -> false
        end)

      assert reply_field == nil, "reply_to field should not appear when absent"
    end
  end

  describe "build_view_xml/2 — XML escaping" do
    test "text with XML metacharacters survives the round-trip" do
      messages = [
        %{
          "id" => "x",
          "ts" => "T0",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => ~s(special <chars> & "quotes" still work),
          "edited?" => false,
          "deleted?" => false
        }
      ]

      xml = ChatViewBuilder.build_view_xml(messages, "general")
      {:ok, view} = parse(xml)

      [msg] = list_messages(view)
      body = find_child(msg, :body)
      [text] = body.children |> Enum.filter(&match?(%ViewXml.Node{tag: :text}, &1))

      assert ViewXml.text_content(text) ==
               ~s(special <chars> & "quotes" still work)
    end
  end

  describe "build_view_xml/2 — output is valid view-XML" do
    test "ArgResolver can resolve actions in the produced view-XML" do
      messages = []
      xml = ChatViewBuilder.build_view_xml(messages, "general")
      {:ok, view} = parse(xml)

      context = %{
        view_path: "/chat/general/_view.xml",
        presence_path: "alice.usr"
      }

      sibling_table = %{
        {"/chat/general", "_messages"} => "msg-uuid",
        {"/chat/general", "_messages.log"} => "log-uuid"
      }

      opts = [sibling_resolver: fn parent, name -> {:ok, sibling_table[{parent, name}]} end]

      assert {:ok, resolved} =
               Commonplace.View.ArgResolver.resolve_action(
                 view,
                 "post_message",
                 %{"text" => "hi"},
                 context,
                 opts
               )

      assert resolved["text"] == "hi"
      assert resolved["messages_uuid"] == "msg-uuid"
      assert resolved["messages_log_uuid"] == "log-uuid"
      assert resolved["room"] == "general"
      assert resolved["author_path"] == "alice.usr"
    end
  end

  # --- Helpers ---

  defp find_action(view, action_name) do
    Enum.find(view.children, fn
      %ViewXml.Node{tag: :action, attrs: %{"name" => ^action_name}} -> true
      _ -> false
    end)
  end

  defp find_messages_list(view) do
    do_find(view, fn
      %ViewXml.Node{tag: :list, attrs: %{"id" => "messages"}} -> true
      _ -> false
    end)
  end

  defp list_messages(view) do
    list = find_messages_list(view)

    Enum.filter(
      list.children,
      &match?(%ViewXml.Node{tag: :entity, attrs: %{"kind" => "message"}}, &1)
    )
  end

  defp find_child(node, tag) do
    Enum.find(node.children, fn
      %ViewXml.Node{tag: ^tag} -> true
      _ -> false
    end)
  end

  defp field_value(msg, name) do
    case Enum.find(msg.children, fn
           %ViewXml.Node{tag: :field, attrs: %{"name" => ^name}} -> true
           _ -> false
         end) do
      %ViewXml.Node{attrs: %{"value" => v}} -> v
      _ -> nil
    end
  end

  defp do_find(%ViewXml.Node{} = node, pred) do
    if pred.(node) do
      node
    else
      Enum.find_value(node.children, fn
        %ViewXml.Node{} = c -> do_find(c, pred)
        _ -> nil
      end)
    end
  end
end
