defmodule Commonplace.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Commonplace.MCP.Protocol

  describe "decode/1 — request parsing" do
    test "parses a valid request with id" do
      line = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}})

      assert {:ok, {:request, 1, "tools/list", %{}}} = Protocol.decode(line)
    end

    test "parses a valid request with string id" do
      line = ~s({"jsonrpc":"2.0","id":"abc","method":"ping"})

      assert {:ok, {:request, "abc", "ping", nil}} = Protocol.decode(line)
    end

    test "parses a notification (no id)" do
      line = ~s({"jsonrpc":"2.0","method":"notifications/initialized"})

      assert {:ok, {:notification, "notifications/initialized", nil}} = Protocol.decode(line)
    end

    test "invalid JSON → {:error, :parse_error}" do
      assert {:error, :parse_error} = Protocol.decode("not json")
      assert {:error, :parse_error} = Protocol.decode("{broken")
    end

    test "missing jsonrpc field → {:error, :invalid_request}" do
      line = ~s({"id":1,"method":"tools/list"})

      assert {:error, :invalid_request} = Protocol.decode(line)
    end

    test "wrong jsonrpc version → {:error, :invalid_request}" do
      line = ~s({"jsonrpc":"1.0","id":1,"method":"tools/list"})

      assert {:error, :invalid_request} = Protocol.decode(line)
    end

    test "missing method → {:error, :invalid_request}" do
      line = ~s({"jsonrpc":"2.0","id":1})

      assert {:error, :invalid_request} = Protocol.decode(line)
    end
  end

  describe "encode_response/2 — success" do
    test "encodes a success response with a map result" do
      json = Protocol.encode_response(1, {:ok, %{"tools" => []}})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"] == %{"tools" => []}
      refute Map.has_key?(decoded, "error")
    end

    test "encodes with a string id" do
      json = Protocol.encode_response("abc", {:ok, "pong"})
      decoded = Jason.decode!(json)

      assert decoded["id"] == "abc"
      assert decoded["result"] == "pong"
    end
  end

  describe "encode_response/2 — error" do
    test "encodes a method-not-found error" do
      json = Protocol.encode_response(1, {:error, :method_not_found, "tools/nope"})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["error"]["code"] == -32601
      assert decoded["error"]["message"] =~ "Method not found"
      assert decoded["error"]["data"] == "tools/nope"
      refute Map.has_key?(decoded, "result")
    end

    test "encodes a parse error with nil id" do
      json = Protocol.encode_response(nil, {:error, :parse_error})
      decoded = Jason.decode!(json)

      assert decoded["id"] == nil
      assert decoded["error"]["code"] == -32700
      assert decoded["error"]["message"] =~ "Parse error"
    end

    test "encodes an invalid-request error" do
      json = Protocol.encode_response(nil, {:error, :invalid_request})
      decoded = Jason.decode!(json)

      assert decoded["error"]["code"] == -32600
      assert decoded["error"]["message"] =~ "Invalid Request"
    end

    test "encodes an internal-error with message detail" do
      json = Protocol.encode_response(2, {:error, :internal_error, "boom"})
      decoded = Jason.decode!(json)

      assert decoded["error"]["code"] == -32603
      assert decoded["error"]["message"] =~ "Internal error"
      assert decoded["error"]["data"] == "boom"
    end

    test "encodes an invalid-params error" do
      json = Protocol.encode_response(3, {:error, :invalid_params, "missing source_uuid"})
      decoded = Jason.decode!(json)

      assert decoded["error"]["code"] == -32602
      assert decoded["error"]["message"] =~ "Invalid params"
      assert decoded["error"]["data"] == "missing source_uuid"
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification with params" do
      json = Protocol.encode_notification("progress", %{"step" => 1})
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "progress"
      assert decoded["params"] == %{"step" => 1}
      refute Map.has_key?(decoded, "id")
    end
  end
end
