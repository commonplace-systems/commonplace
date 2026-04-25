defmodule Commonplace.MCP.MetaToolsTest do
  @moduledoc """
  CX-y3q meta-tools: `list_tools` returns the live catalog, `call_tool`
  late-binds to any tool by name. Recursive guard: meta-tools are NOT
  in the dispatchable catalog, so `call_tool({name: "call_tool", ...})`
  → `:not_found`.

  These tests exercise the meta-tool descriptors + dispatch via
  `Commonplace.MCP.Tools.call/3`. Full integration through the
  AnubisServer's handle_request is covered separately.
  """
  use ExUnit.Case, async: true

  alias Commonplace.MCP.Tools

  describe "list_tools meta-tool" do
    test "is callable via Tools.call" do
      assert {:ok, _result} = Tools.call("list_tools", %{})
    end

    test "returns the merged catalog (system tools, no meta-tools)" do
      {:ok, result} = Tools.call("list_tools", %{})

      structured =
        result["content"]
        |> Enum.at(1)
        |> Map.get("text")
        |> Jason.decode!()

      names = Enum.map(structured["tools"], & &1["name"])

      # System tools present
      assert "cat" in names
      assert "presence_info" in names

      # Meta-tools deliberately absent
      refute "call_tool" in names
      refute "list_tools" in names
    end
  end

  describe "call_tool meta-tool" do
    test "dispatches to a system tool by name" do
      assert {:ok, _result} =
               Tools.call("call_tool", %{"name" => "presence_info", "args" => %{}})
    end

    test "passes context through to the inner tool" do
      ctx = %{
        presence_uuid: "p",
        mailbox_uuid: "m",
        mailbox_topic: "agents/x"
      }

      {:ok, result} =
        Tools.call("call_tool", %{"name" => "presence_info", "args" => %{}}, ctx)

      structured =
        result["content"]
        |> Enum.at(1)
        |> Map.get("text")
        |> Jason.decode!()

      assert structured["presence_uuid"] == "p"
      assert structured["mailbox_uuid"] == "m"
    end

    test "returns :invalid_params when name is missing" do
      assert {:error, :invalid_params, _} = Tools.call("call_tool", %{})
    end

    test "recursive guard: cannot call call_tool through call_tool" do
      assert {:error, :not_found} =
               Tools.call("call_tool", %{"name" => "call_tool", "args" => %{}})
    end

    test "recursive guard: cannot call list_tools through call_tool" do
      assert {:error, :not_found} =
               Tools.call("call_tool", %{"name" => "list_tools", "args" => %{}})
    end
  end

  describe "Tools.list/0" do
    test "includes system tools and excludes meta-tools" do
      catalog = Tools.list()
      names = Enum.map(catalog, & &1["name"])

      assert "cat" in names
      assert "presence_info" in names
      refute "call_tool" in names
      refute "list_tools" in names
    end
  end
end
