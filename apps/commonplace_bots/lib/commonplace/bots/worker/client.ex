defmodule Commonplace.Bots.Worker.Client do
  @moduledoc """
  Thin Anthropic Messages API client.

  One function: `call(request_map)` → `{:ok, response} | {:error, term}`.
  No streaming; one HTTP request per cave-diver turn.

  ## Auth

  Reads `ANTHROPIC_API_KEY` from the environment at call time. A
  missing key returns `{:error, :missing_api_key}` rather than
  raising — the dispatcher continues for other bots, the worker
  outcome is captured in telemetry.

  ## Why not stream

  v0 workers have hard caps on output tokens and wall-clock; the
  cap-driven termination is simpler against full-response bodies.
  Streaming is a viable upgrade path (token-incremental cap
  enforcement, partial-text observability) but not required for
  the acceptance test.

  ## Configurable endpoint

  Default endpoint is `https://api.anthropic.com/v1/messages`.
  Overridable via the `:endpoint` option in the request map — for
  tests that point at a local mock server.
  """

  @endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"

  @spec call(map()) :: {:ok, map()} | {:error, term()}
  def call(request) when is_map(request) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error, :missing_api_key}

      "" ->
        {:error, :missing_api_key}

      key ->
        endpoint = Map.get(request, :endpoint, @endpoint)
        body = build_body(request)

        Req.post(endpoint,
          json: body,
          headers: [
            {"x-api-key", key},
            {"anthropic-version", @anthropic_version}
          ],
          receive_timeout: 60_000
        )
        |> handle_result()
    end
  end

  defp build_body(request) do
    %{
      "model" => Map.fetch!(request, :model),
      "system" => Map.fetch!(request, :system),
      "messages" => Map.fetch!(request, :messages),
      "tools" => Map.get(request, :tools, []),
      "max_tokens" => Map.fetch!(request, :max_tokens)
    }
  end

  defp handle_result({:ok, %Req.Response{status: 200, body: body}}) when is_map(body) do
    {:ok, body}
  end

  defp handle_result({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http_status, status, body}}
  end

  defp handle_result({:error, exception}) do
    {:error, {:transport_error, exception}}
  end
end
