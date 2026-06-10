defmodule Commonplace.MCP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 encode/decode for the Model Context Protocol over stdio.

  MCP stdio transport frames each message as a single line of JSON. This
  module is the pure protocol layer: no IO, no dispatching, no state.

  > **Status — superseded but retained.** This is the *hand-rolled*
  > JSON-RPC stack (`Stdio` + `Commonplace.MCP.Server` + this module).
  > The escript no longer wires it to stdin: all live MCP traffic is
  > served by `Commonplace.MCP.AnubisServer` (anubis_mcp), which owns
  > the wire protocol. This module is kept on disk — with full test
  > coverage, so the codec stays correct — until CX-xaof removes it.
  > Edit it for the legacy path or its tests, not to change live
  > behavior.

  ## Decoded request shapes

    * `{:request, id, method, params}` — regular method call with an id
      that the server must reply to. `params` is a map (or `nil` if absent).
    * `{:notification, method, params}` — one-way, no response expected.

  ## Error response shorthands

  `encode_response/2` accepts:

    * `{:ok, result}`
    * `{:error, :parse_error}`          → code -32700
    * `{:error, :invalid_request}`      → code -32600
    * `{:error, :method_not_found, method_name}` → code -32601
    * `{:error, :invalid_params, detail}`        → code -32602
    * `{:error, :internal_error, detail}`        → code -32603

  The three-element error tuples carry their `detail`/`method` in the
  JSON-RPC error object's `data` field; `:parse_error` and
  `:invalid_request` have no `data`.

  ## Server-initiated notifications

  `encode_notification/2` builds a one-way server→client frame
  (`method` + `params`, no `id`, so no reply is expected) — the encode
  counterpart of a decoded `{:notification, …}`.
  """

  @type id :: integer() | String.t() | nil
  @type method :: String.t()
  @type params :: map() | nil

  @type decoded ::
          {:request, id(), method(), params()}
          | {:notification, method(), params()}

  @type decode_error :: :parse_error | :invalid_request

  @type encode_result ::
          {:ok, any()}
          | {:error, :parse_error}
          | {:error, :invalid_request}
          | {:error, :method_not_found, String.t()}
          | {:error, :invalid_params, String.t()}
          | {:error, :internal_error, String.t()}

  @spec decode(String.t()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} -> extract(msg)
      {:ok, _} -> {:error, :invalid_request}
      {:error, _} -> {:error, :parse_error}
    end
  end

  defp extract(%{"method" => method} = msg) when is_binary(method) do
    params = Map.get(msg, "params")

    case Map.fetch(msg, "id") do
      :error -> {:ok, {:notification, method, params}}
      {:ok, id} -> {:ok, {:request, id, method, params}}
    end
  end

  defp extract(_), do: {:error, :invalid_request}

  @spec encode_response(id(), encode_result()) :: iodata()
  def encode_response(id, {:ok, result}) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    })
  end

  def encode_response(id, {:error, :parse_error}) do
    error_response(id, -32700, "Parse error")
  end

  def encode_response(id, {:error, :invalid_request}) do
    error_response(id, -32600, "Invalid Request")
  end

  def encode_response(id, {:error, :method_not_found, method}) do
    error_response(id, -32601, "Method not found", method)
  end

  def encode_response(id, {:error, :invalid_params, detail}) do
    error_response(id, -32602, "Invalid params", detail)
  end

  def encode_response(id, {:error, :internal_error, detail}) do
    error_response(id, -32603, "Internal error", detail)
  end

  @spec encode_notification(String.t(), map()) :: iodata()
  def encode_notification(method, params) when is_binary(method) and is_map(params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    })
  end

  defp error_response(id, code, message) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp error_response(id, code, message, data) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message, "data" => data}
    })
  end
end
