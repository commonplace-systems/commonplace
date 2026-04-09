defmodule Commonplace.MCP.Stdio do
  @moduledoc """
  Line-delimited JSON-RPC loop over stdio (or any reader/emit pair).

  `run/2` is the test-friendly entrypoint: it takes a `reader` function
  that returns one line at a time (or `:eof`) and an `emit` function that
  writes each response line to the output. This indirection lets us drive
  the loop from in-process tests without a real OS process.

  `run_stdio/0` is the production entrypoint used by the escript — it
  wires the reader to `:io.get_line/1` and the emitter to `IO.puts/1`.

  Each line is parsed as JSON-RPC 2.0 via `Protocol.decode/1`, dispatched
  through `Server.handle/2`, and the outcome is encoded back via
  `Protocol.encode_response/2`. Notifications produce no output.
  """

  alias Commonplace.MCP.{Protocol, Server}

  @type reader :: (-> String.t() | :eof)
  @type emitter :: (String.t() -> any())

  @spec run(reader(), emitter()) :: Server.t()
  def run(reader, emitter) when is_function(reader, 0) and is_function(emitter, 1) do
    loop(Server.new(), reader, emitter)
  end

  @doc "Production entrypoint — reads from stdin, writes to stdout."
  @spec run_stdio() :: Server.t()
  def run_stdio do
    reader = fn ->
      case IO.gets(:stdio, "") do
        :eof -> :eof
        {:error, _} -> :eof
        line -> line
      end
    end

    emitter = fn line -> IO.puts(line) end

    run(reader, emitter)
  end

  defp loop(server, reader, emitter) do
    case reader.() do
      :eof ->
        server

      line ->
        trimmed = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

        if trimmed == "" do
          loop(server, reader, emitter)
        else
          server = handle_line(server, trimmed, emitter)
          loop(server, reader, emitter)
        end
    end
  end

  defp handle_line(server, line, emitter) do
    case Protocol.decode(line) do
      {:ok, {:request, id, _method, _params} = request} ->
        case Server.handle(server, request) do
          {:ok, result, server} ->
            emitter.(Protocol.encode_response(id, {:ok, result}))
            server

          {:error, kind, server} ->
            emitter.(Protocol.encode_response(id, {:error, kind}))
            server

          {:error, kind, detail, server} ->
            emitter.(Protocol.encode_response(id, {:error, kind, detail}))
            server
        end

      {:ok, {:notification, _method, _params} = notification} ->
        case Server.handle(server, notification) do
          {:noreply, server} -> server
          _ -> server
        end

      {:error, :parse_error} ->
        emitter.(Protocol.encode_response(nil, {:error, :parse_error}))
        server

      {:error, :invalid_request} ->
        emitter.(Protocol.encode_response(nil, {:error, :invalid_request}))
        server
    end
  end
end
