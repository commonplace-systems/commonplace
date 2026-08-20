defmodule Commonplace.Test.CodexFaithfulVendor do
  @moduledoc """
  A fake vendor faithful to what CODEX PARSES, not merely to the wire.

  The M-CUTOVER-1 integration run needs codex to COMPLETE a turn through
  the mediator→relay path. `MediatorFakeVendor` emits a stub SSE stream
  (`data: 1`) that exercises the byte pipe but skips codex's completion
  path. This vendor emits the minimal responses-API event sequence codex
  actually consumes — the event names were EXTRACTED FROM THE CODEX
  BINARY (`strings` over codex-linux-x64), not reconstructed from memory:

      response.created
      response.output_item.added
      response.output_text.delta   (the assistant text)
      response.output_item.done
      response.completed

  Each as one SSE frame `event: <type>\\ndata: <json>\\n\\n`. The turn
  yields a fixed assistant text (default "ACK") so the integration
  assertion is deterministic.

  ⛔ TEST/DRY-RUN INSTRUMENT ONLY. It authenticates nothing and returns a
  canned turn; it exists to prove the STACK carries a completable turn,
  never to stand in for a real vendor's behavior (that is GAP-4's single
  scoped real-vendor run).
  """

  import Plug.Conn

  @default_text "ACK"

  def init(opts), do: opts

  def call(conn, opts) do
    state = Keyword.fetch!(opts, :state)
    {body, conn} = read_entire_body(conn)

    Agent.update(state, fn v ->
      Map.update(v, :requests, [%{path: conn.request_path, body: body}], fn rs ->
        rs ++ [%{path: conn.request_path, body: body}]
      end)
    end)

    respond(conn, conn.request_path, opts)
  end

  # The vendor's token endpoint: hand back a fresh pair so a refresh
  # probe in the stack does not fail the integration on the auth axis
  # (auth correctness is the mediator's own tests; here it must simply
  # not block the completion path).
  defp respond(conn, "/oauth/token", _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{access_token: "access-new", refresh_token: "refresh-new"}))
  end

  defp respond(conn, "/v1/responses", opts) do
    text = Keyword.get(opts, :assistant_text, @default_text)
    response_id = "resp_" <> Integer.to_string(System.unique_integer([:positive]))
    item_id = "msg_" <> Integer.to_string(System.unique_integer([:positive]))

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    conn
    |> sse("response.created", %{
      type: "response.created",
      response: %{id: response_id, status: "in_progress"}
    })
    |> sse("response.output_item.added", %{
      type: "response.output_item.added",
      output_index: 0,
      item: %{id: item_id, type: "message", role: "assistant", status: "in_progress"}
    })
    # NOTE (integration run 2026-08-20): codex logs a non-fatal
    # "OutputTextDelta without active item" against this minimal sequence
    # and COMPLETES anyway (ACK, exit 0). Adding content_part.added/done
    # did not clear that internal state-machine line, so the minimal
    # five-event sequence is kept — it provably drives codex to complete a
    # turn, which is what the integration proves; the log line is a
    # recorded fidelity finding, not a blocker.
    |> sse("response.output_text.delta", %{
      type: "response.output_text.delta",
      item_id: item_id,
      output_index: 0,
      content_index: 0,
      delta: text
    })
    |> sse("response.output_item.done", %{
      type: "response.output_item.done",
      output_index: 0,
      item: %{
        id: item_id,
        type: "message",
        role: "assistant",
        status: "completed",
        content: [%{type: "output_text", text: text}]
      }
    })
    |> sse("response.completed", %{
      type: "response.completed",
      response: %{
        id: response_id,
        status: "completed",
        output: [
          %{
            id: item_id,
            type: "message",
            role: "assistant",
            content: [%{type: "output_text", text: text}]
          }
        ]
      }
    })
  end

  defp respond(conn, _path, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "unmapped codex-faithful fake request"}))
  end

  defp sse(conn, event, data) do
    {:ok, conn} = chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n")
    conn
  end

  defp read_entire_body(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, body, conn} -> {IO.iodata_to_binary(Enum.reverse([body | acc])), conn}
      {:more, body, conn} -> read_entire_body(conn, [body | acc])
    end
  end
end
