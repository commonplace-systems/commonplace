defmodule Commonplace.View.ArgResolverTest do
  @moduledoc """
  CX-azwh (sub-bead i of CX-04d8 M3): substrate-tier ArgResolver primitive.

  Tests cover the three enumerated resolver kinds (`..`, `../{name}`,
  `$session.{key}`), caller-wins maybe_put semantics, and the parser
  fix that adds `:arg` to ViewXml's @known_tags.

  Synthetic non-chat fixture is a "task list" view declaring a non-chat
  action whose <arg> children resolve through the same primitive — proves
  the resolver isn't chat-specific.
  """
  use ExUnit.Case, async: true

  alias Commonplace.View.ArgResolver
  alias Commonplace.Document.ViewXml

  # Stub sibling resolver for unit tests — keyed lookup table.
  defp stub_sibling_resolver(table) do
    fn parent_path, name ->
      case Map.fetch(table, {parent_path, name}) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, {:no_sibling, name}}
      end
    end
  end

  defp parse_action(xml) do
    {:ok, %ViewXml.Node{tag: :view, children: children}} = ViewXml.parse(xml)

    Enum.find(children, fn
      %ViewXml.Node{tag: :action} -> true
      _ -> false
    end)
  end

  describe "@known_tags includes :arg" do
    test "ViewXml parses <arg> as a known node (not :unknown)" do
      xml = """
      <view>
        <action name="post" args="text:string">
          <arg name="messages_uuid" from="../_messages"/>
        </action>
      </view>
      """

      action = parse_action(xml)
      assert action != nil

      [arg | _] = action.children |> Enum.filter(&match?(%ViewXml.Node{}, &1))
      assert arg.tag == :arg, "expected <arg> to parse as :arg, got #{inspect(arg.tag)}"
      assert arg.attrs["name"] == "messages_uuid"
      assert arg.attrs["from"] == "../_messages"
    end
  end

  describe "resolve/4 — `..` parent-dir resolver" do
    test "resolves `..` to parent dir basename" do
      xml = """
      <view>
        <action name="post" args="text:string">
          <arg name="room" from=".."/>
        </action>
      </view>
      """

      action = parse_action(xml)
      context = %{view_path: "/chat/general/_view.xml"}

      assert {:ok, %{"room" => "general"}} = ArgResolver.resolve(action, %{}, context)
    end

    test "errors when view_path is missing" do
      xml = ~s(<view><action name="x"><arg name="r" from=".."/></action></view>)
      action = parse_action(xml)

      assert {:error, reason} = ArgResolver.resolve(action, %{}, %{})
      assert reason =~ "view_path"
    end
  end

  describe "resolve/4 — `../{name}` sibling resolver" do
    test "resolves `../foo` to sibling-by-name lookup result" do
      xml = """
      <view>
        <action name="post">
          <arg name="messages_uuid" from="../_messages"/>
        </action>
      </view>
      """

      action = parse_action(xml)
      context = %{view_path: "/chat/general/_view.xml"}

      sibling_table = %{{"/chat/general", "_messages"} => "uuid-abc"}
      opts = [sibling_resolver: stub_sibling_resolver(sibling_table)]

      assert {:ok, %{"messages_uuid" => "uuid-abc"}} =
               ArgResolver.resolve(action, %{}, context, opts)
    end

    test "propagates sibling-resolver errors as {:error, reason}" do
      xml = ~s(<view><action name="x"><arg name="m" from="../missing"/></action></view>)
      action = parse_action(xml)
      context = %{view_path: "/chat/general/_view.xml"}

      opts = [sibling_resolver: stub_sibling_resolver(%{})]

      assert {:error, _reason} = ArgResolver.resolve(action, %{}, context, opts)
    end

    test "errors when view_path is missing for sibling lookup" do
      xml = ~s(<view><action name="x"><arg name="m" from="../foo"/></action></view>)
      action = parse_action(xml)

      assert {:error, _reason} = ArgResolver.resolve(action, %{}, %{})
    end
  end

  describe "resolve/4 — `$session.{key}` context-lookup resolver" do
    test "resolves `$session.foo` to context's :foo value (atom key)" do
      xml = """
      <view>
        <action name="post">
          <arg name="author_path" from="$session.presence_path"/>
        </action>
      </view>
      """

      action = parse_action(xml)
      context = %{presence_path: "alice.usr"}

      assert {:ok, %{"author_path" => "alice.usr"}} =
               ArgResolver.resolve(action, %{}, context)
    end

    test "resolves `$session.foo` to context's \"foo\" value (string key)" do
      xml = ~s(<view><action name="x"><arg name="user" from="$session.user_id"/></action></view>)
      action = parse_action(xml)
      context = %{"user_id" => "u-123"}

      assert {:ok, %{"user" => "u-123"}} = ArgResolver.resolve(action, %{}, context)
    end

    test "drops the arg silently when context value is nil" do
      xml = ~s(<view><action name="x"><arg name="user" from="$session.absent"/></action></view>)
      action = parse_action(xml)

      assert {:ok, resolved} = ArgResolver.resolve(action, %{}, %{})
      refute Map.has_key?(resolved, "user"),
             "nil from $session.X should drop arg, not insert nil"
    end
  end

  describe "resolve/4 — caller-wins maybe_put semantics" do
    test "supplied args win over resolver output" do
      xml = """
      <view>
        <action name="post">
          <arg name="room" from=".."/>
          <arg name="author_path" from="$session.presence_path"/>
        </action>
      </view>
      """

      action = parse_action(xml)

      context = %{
        view_path: "/chat/general/_view.xml",
        presence_path: "alice.usr"
      }

      supplied = %{"room" => "explicit-room", "author_path" => "explicit-author"}

      assert {:ok, resolved} = ArgResolver.resolve(action, supplied, context)
      assert resolved["room"] == "explicit-room", "caller's room must win"
      assert resolved["author_path"] == "explicit-author", "caller's author_path must win"
    end

    test "supplied args coexist with resolver-filled gaps" do
      xml = """
      <view>
        <action name="post">
          <arg name="room" from=".."/>
          <arg name="author_path" from="$session.presence_path"/>
        </action>
      </view>
      """

      action = parse_action(xml)

      context = %{
        view_path: "/chat/general/_view.xml",
        presence_path: "alice.usr"
      }

      supplied = %{"room" => "explicit-room"}

      assert {:ok, %{"room" => "explicit-room", "author_path" => "alice.usr"}} =
               ArgResolver.resolve(action, supplied, context)
    end
  end

  describe "resolve/4 — empty / no-op cases" do
    test "action with no <arg> children returns supplied args unchanged" do
      xml = ~s(<view><action name="x" args="text:string"/></view>)
      action = parse_action(xml)

      assert {:ok, %{"text" => "hello"}} =
               ArgResolver.resolve(action, %{"text" => "hello"}, %{})
    end

    test "unknown from-syntax returns {:error, _}" do
      xml = ~s(<view><action name="x"><arg name="b" from="$other.foo"/></action></view>)
      action = parse_action(xml)

      assert {:error, reason} = ArgResolver.resolve(action, %{}, %{})
      assert reason =~ "unknown" or reason =~ "from"
    end
  end

  describe "resolve/4 — non-chat synthetic anchor (substrate domain-agnosticism)" do
    @doc """
    A "task list" view declaring `complete_task` action with three
    declarative <arg> children — none of which are chat-shaped. Proves
    the substrate primitive isn't specialized to chat.
    """
    test "task-list view's complete_task action resolves correctly" do
      xml = """
      <view>
        <entity kind="task_list" name="my-tasks">
          <list id="tasks"/>
        </entity>
        <action name="complete_task" args="task_id:string">
          <arg name="tasks_uuid" from="../_tasks"/>
          <arg name="list_name" from=".."/>
          <arg name="user_id" from="$session.user_id"/>
        </action>
      </view>
      """

      action = parse_action(xml)

      context = %{
        view_path: "/projects/website/_view.xml",
        user_id: "u-789"
      }

      sibling_table = %{{"/projects/website", "_tasks"} => "tasks-uuid-99"}
      opts = [sibling_resolver: stub_sibling_resolver(sibling_table)]

      supplied = %{"task_id" => "task-42"}

      assert {:ok, resolved} = ArgResolver.resolve(action, supplied, context, opts)

      assert resolved["task_id"] == "task-42"
      assert resolved["tasks_uuid"] == "tasks-uuid-99"
      assert resolved["list_name"] == "website"
      assert resolved["user_id"] == "u-789"
    end
  end
end
