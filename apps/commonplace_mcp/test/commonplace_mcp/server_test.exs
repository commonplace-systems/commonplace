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

  defp stub_presence_starter do
    # Returns a function compatible with Server's :presence_starter hook.
    # Records every call so tests can verify what the server asked for.
    test_pid = self()

    fn name, type ->
      send(test_pid, {:presence_started, name, type})
      {:ok, %{pid: self(), name: name, type: type, uuid: "uuid-" <> name}}
    end
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

    test "with a presence_starter, spawns a .bot presence and records its uuid" do
      s = Server.new(presence_starter: stub_presence_starter())

      request = {:request, 1, "initialize",
                 %{"protocolVersion" => "2025-06-18",
                   "clientInfo" => %{"name" => "claude-code", "version" => "1.0"}}}

      assert {:ok, result, s2} = Server.handle(s, request)

      # Presence starter was called with the client name and :bot type
      assert_received {:presence_started, "claude-code", :bot}

      # The presence uuid is exposed in the initialize response and state
      assert result["serverInfo"]["presenceUuid"] == "uuid-claude-code"
      assert Server.presence_uuid(s2) == "uuid-claude-code"
    end

    test "with a presence_starter but no clientInfo name, uses 'mcp-agent' as default" do
      s = Server.new(presence_starter: stub_presence_starter())

      request = {:request, 1, "initialize",
                 %{"protocolVersion" => "2025-06-18"}}

      assert {:ok, _result, _s2} = Server.handle(s, request)
      assert_received {:presence_started, "mcp-agent", :bot}
    end

    test "without a presence_starter, skips bootstrap (pure-mode default)", %{server: s} do
      request = {:request, 1, "initialize",
                 %{"protocolVersion" => "2025-06-18",
                   "clientInfo" => %{"name" => "bare", "version" => "1"}}}

      assert {:ok, result, s2} = Server.handle(s, request)
      refute Map.has_key?(result["serverInfo"], "presenceUuid")
      assert Server.presence_uuid(s2) == nil
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
