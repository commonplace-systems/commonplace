defmodule Commonplace.MCP.StdioTest do
  @moduledoc """
  Integration-level test of the stdio loop: we give the loop a stream of
  input lines and an output sink, run it to exhaustion, and inspect the
  encoded JSON responses.

  The loop itself doesn't touch stdin/stdout directly — it takes an input
  and output function, which makes it testable in-process.
  """

  use ExUnit.Case, async: true

  alias Commonplace.MCP.Stdio

  defp run(lines) do
    # Use an Agent as a simple sink to capture responses line-by-line.
    {:ok, sink} = Agent.start_link(fn -> [] end)

    emit = fn line ->
      Agent.update(sink, fn acc -> acc ++ [line] end)
    end

    reader = reader_fn(lines)
    Stdio.run(reader, emit)

    out = Agent.get(sink, & &1)
    Agent.stop(sink)
    out
  end

  defp reader_fn(lines) do
    {:ok, agent} = Agent.start_link(fn -> lines end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {:eof, []}
        [line | rest] -> {line, rest}
      end)
    end
  end

  describe "stdio loop" do
    test "responds to an initialize request" do
      init =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      [resp] = run([init])

      decoded = Jason.decode!(resp)
      assert decoded["id"] == 1
      assert decoded["result"]["protocolVersion"] == "2025-06-18"
      assert decoded["result"]["serverInfo"]["name"] == "commonplace-mcp"
    end

    test "handles initialize then tools/list round-trip" do
      init =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      initialized =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized"
        })

      tools =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        })

      responses = run([init, initialized, tools])
      # Expect exactly 2 responses (init + tools/list; notification has no reply)
      assert length(responses) == 2

      [init_resp, tools_resp] = responses
      assert Jason.decode!(init_resp)["id"] == 1

      tools_decoded = Jason.decode!(tools_resp)
      assert tools_decoded["id"] == 2
      assert is_list(tools_decoded["result"]["tools"])
    end

    test "invalid JSON produces a parse_error response" do
      [resp] = run(["not json at all"])
      decoded = Jason.decode!(resp)
      assert decoded["error"]["code"] == -32700
      assert decoded["id"] == nil
    end

    test "unknown method after initialize produces method_not_found" do
      init =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      bogus =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "bogus/thing"
        })

      [_init_resp, bogus_resp] = run([init, bogus])
      decoded = Jason.decode!(bogus_resp)
      assert decoded["id"] == 2
      assert decoded["error"]["code"] == -32601
      assert decoded["error"]["data"] == "bogus/thing"
    end

    test "skips empty lines" do
      init =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-06-18",
            "clientInfo" => %{"name" => "test", "version" => "1.0"}
          }
        })

      responses = run(["", init, ""])
      assert length(responses) == 1
    end
  end
end
