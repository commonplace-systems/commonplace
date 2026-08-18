defmodule Commonplace.Test.MediatorFakeVendor do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    owner = Keyword.fetch!(opts, :owner)
    state = Keyword.fetch!(opts, :state)
    {body, conn} = read_entire_body(conn)
    request = %{path: conn.request_path, headers: conn.req_headers, body: body}

    action =
      Agent.get_and_update(state, fn vendor ->
        action = action(vendor, request)
        {action, update_vendor(vendor, request, action)}
      end)

    respond(conn, owner, action)
  end

  defp action(_vendor, %{path: "/oauth/token"}),
    do: {:json, 200, %{access_token: "access-new", refresh_token: "refresh-new"}}

  defp action(%{mode: :stream}, %{path: "/v1/responses"}), do: :stream

  defp action(%{mode: :refresh}, %{path: "/v1/responses", headers: headers}) do
    case header(headers, "authorization") do
      "Bearer access-old" -> {:json, 401, %{error: "expired"}}
      "Bearer access-new" -> :sse
      _other -> {:json, 403, %{error: "wrong credential"}}
    end
  end

  defp action(%{mode: :always_401}, %{path: "/v1/responses"}),
    do: {:json, 401, %{error: "still unauthorized"}}

  defp action(_vendor, _request), do: {:json, 404, %{error: "unmapped fake request"}}

  defp update_vendor(vendor, request, action) do
    vendor
    |> Map.update!(:requests, &(&1 ++ [request]))
    |> Map.put(:last_action, action)
  end

  defp respond(conn, owner, :stream) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    {:ok, conn} = chunk(conn, "event: one\ndata: 1\n\n")
    send(owner, {:vendor_sent_first_event, self()})

    receive do
      :release_second_event -> :ok
    after
      5_000 -> raise "stream test never released the second event"
    end

    {:ok, conn} = chunk(conn, "event: two\ndata: 2\n\n")
    conn
  end

  defp respond(conn, _owner, :sse) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200, "data: refreshed\n\n")
  end

  defp respond(conn, _owner, {:json, status, body}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp read_entire_body(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, body, conn} -> {IO.iodata_to_binary(Enum.reverse([body | acc])), conn}
      {:more, body, conn} -> read_entire_body(conn, [body | acc])
    end
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end
