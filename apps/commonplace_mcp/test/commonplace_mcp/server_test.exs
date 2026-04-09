defmodule Commonplace.MCP.ServerTest do
  @moduledoc """
  Unit tests for the pure-ish dispatch layer. The Server routes parsed
  Protocol requests to the right handler, returns a response tuple, and
  tracks initialization state across calls.
  """

  use ExUnit.Case, async: true

  alias Commonplace.MCP.Server

  setup do
    {:ok, server: Server.new()}
  end

  describe "initialize" do
    test "responds with server info and capabilities", %{server: s} do
      request = {:request, 1, "initialize",
                 %{"protocolVersion" => "2025-06-18",
                   "clientInfo" => %{"name" => "claude-code", "version" => "1.0"}}}

      assert {:ok, result, s2} = Server.handle(s, request)
      assert result["protocolVersion"] == "2025-06-18"
      assert result["serverInfo"]["name"] == "commonplace-mcp"
      assert is_binary(result["serverInfo"]["version"])
      assert is_map(result["capabilities"])
      assert is_map(result["capabilities"]["tools"])
      assert Server.initialized?(s2)
    end

    test "records client info in the server state", %{server: s} do
      request = {:request, 1, "initialize",
                 %{"protocolVersion" => "2025-06-18",
                   "clientInfo" => %{"name" => "claude-code", "version" => "1.0"}}}

      assert {:ok, _result, s2} = Server.handle(s, request)
      assert Server.client_name(s2) == "claude-code"
    end
  end

  describe "before initialize" do
    test "non-initialize request returns invalid_request", %{server: s} do
      request = {:request, 1, "tools/list", %{}}

      assert {:error, :invalid_request, _state} = Server.handle(s, request)
    end
  end

  describe "tools/list" do
    test "returns the registered tool list after initialize", %{server: s} do
      s = initialize(s)

      request = {:request, 2, "tools/list", %{}}

      assert {:ok, result, _s2} = Server.handle(s, request)
      assert is_list(result["tools"])
      assert Enum.any?(result["tools"], &(&1["name"] == "fork"))
      assert Enum.any?(result["tools"], &(&1["name"] == "tail_red"))
      assert Enum.any?(result["tools"], &(&1["name"] == "send_magenta"))

      # Every tool has a description and inputSchema
      for tool <- result["tools"] do
        assert is_binary(tool["description"])
        assert is_map(tool["inputSchema"])
        assert tool["inputSchema"]["type"] == "object"
      end
    end
  end

  describe "tools/call — unknown tool" do
    test "returns method_not_found", %{server: s} do
      s = initialize(s)

      request = {:request, 3, "tools/call",
                 %{"name" => "not_a_real_tool", "arguments" => %{}}}

      assert {:error, :method_not_found, "not_a_real_tool", _state} =
               Server.handle(s, request)
    end
  end

  describe "unknown top-level method" do
    test "returns method_not_found", %{server: s} do
      s = initialize(s)

      request = {:request, 4, "nonsense/verb", %{}}

      assert {:error, :method_not_found, "nonsense/verb", _state} =
               Server.handle(s, request)
    end
  end

  describe "notifications/initialized" do
    test "is accepted after initialize and returns no response", %{server: s} do
      s = initialize(s)

      notification = {:notification, "notifications/initialized", nil}

      assert {:noreply, _s2} = Server.handle(s, notification)
    end
  end

  # --- helpers ---

  defp initialize(s) do
    request = {:request, 1, "initialize",
               %{"protocolVersion" => "2025-06-18",
                 "clientInfo" => %{"name" => "test-client", "version" => "0.0.1"}}}

    {:ok, _result, s2} = Server.handle(s, request)
    s2
  end
end
