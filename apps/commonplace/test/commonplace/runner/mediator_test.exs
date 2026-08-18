defmodule Commonplace.Runner.MediatorTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.Mediator
  alias Commonplace.Test.MediatorFakeVendor

  setup do
    root = Path.join(System.tmp_dir!(), "mediator_r1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {public_key, private_key} = Signing.generate_keypair()

    %{root: root, public_key: public_key, private_key: private_key}
  end

  test "valid socket-bound token replaces pod authorization and streams before completion", ctx do
    {vendor, vendor_state} = start_vendor(:stream)
    {mediator, sockets} = start_mediator(ctx, vendor)
    body = ~s({"input":"byte-identical body"})
    token = token(ctx, "deployment-a")

    response =
      Req.post!("http://localhost/v1/responses",
        unix_socket: sockets["deployment-a"],
        headers: [accept: "text/event-stream", authorization: "Bearer #{token}"],
        body: body,
        into: :self,
        retry: false
      )

    assert response.status == 200
    assert_receive {:vendor_sent_first_event, vendor_request}, 1_000

    assert next_message(response) == {:ok, data: "event: one\ndata: 1\n\n"}

    send(vendor_request, :release_second_event)

    assert next_message(response) == {:ok, data: "event: two\ndata: 2\n\n"}

    assert next_message(response) == {:ok, [:done]}

    assert [%{body: ^body, headers: headers}] = vendor_requests(vendor_state, "/v1/responses")
    assert header(headers, "authorization") == "Bearer access-old"
    assert Mediator.request_count(mediator, "deployment-a") == 1
  end

  test "garbage token is named and never forwarded", ctx do
    {_vendor, vendor_state, sockets} = refusal_fixture(ctx)

    response = request(sockets["deployment-a"], "garbage")

    assert_refusal(response, 400, "invalid_token")
    assert vendor_requests(vendor_state, "/v1/responses") == []
  end

  test "token identity mismatching the addressed socket is named and never forwarded", ctx do
    {_vendor, vendor_state, sockets} = refusal_fixture(ctx)

    response = request(sockets["deployment-a"], token(ctx, "deployment-b"))

    assert_refusal(response, 400, "identity_mismatch")
    assert vendor_requests(vendor_state, "/v1/responses") == []
  end

  test "expired token is named and never forwarded", ctx do
    {_vendor, vendor_state, sockets} = refusal_fixture(ctx)

    response = request(sockets["deployment-a"], token(ctx, "deployment-a", -1))

    assert_refusal(response, 400, "expired_token")
    assert vendor_requests(vendor_state, "/v1/responses") == []
  end

  test "revoked token is named and never forwarded", ctx do
    {_vendor, vendor_state, sockets, mediator} = refusal_fixture(ctx, return_mediator: true)
    revoked = token(ctx, "deployment-a")
    :ok = Mediator.revoke_token(mediator, revoked)

    response = request(sockets["deployment-a"], revoked)

    assert_refusal(response, 400, "revoked_token")
    assert vendor_requests(vendor_state, "/v1/responses") == []
  end

  test "vendor down is named within a bounded time", ctx do
    dead_port = unused_tcp_port()
    {_mediator, sockets} = start_mediator(ctx, "http://127.0.0.1:#{dead_port}")

    task = Task.async(fn -> request(sockets["deployment-a"], token(ctx, "deployment-a")) end)
    response = Task.await(task, 2_000)

    assert_refusal(response, 424, "vendor_unreachable")
  end

  test "401 refreshes once, persists the pair, and a second 401 is named", ctx do
    {_vendor, vendor_state} = start_vendor(:refresh)
    {mediator, sockets} = start_mediator(ctx, vendor_url(vendor_state))
    valid = token(ctx, "deployment-a")

    assert request(sockets["deployment-a"], valid).status == 200
    assert request(sockets["deployment-a"], valid).status == 200

    response_auth =
      vendor_requests(vendor_state, "/v1/responses")
      |> Enum.map(&header(&1.headers, "authorization"))

    assert response_auth == ["Bearer access-old", "Bearer access-new", "Bearer access-new"]
    assert refresh_tokens(vendor_state) == ["refresh-old"]

    Agent.update(vendor_state, &Map.put(&1, :mode, :always_401))
    assert_refusal(request(sockets["deployment-a"], valid), 400, "vendor_unauthorized")
    assert refresh_tokens(vendor_state) == ["refresh-old", "refresh-new"]
    assert Mediator.request_count(mediator, "deployment-a") == 3
  end

  test "counts requests independently across two deployment sockets", ctx do
    {vendor, _vendor_state} = start_vendor(:refresh)
    {mediator, sockets} = start_mediator(ctx, vendor)

    Enum.each(1..3, fn _ ->
      assert request(sockets["deployment-a"], token(ctx, "deployment-a")).status == 200
    end)

    Enum.each(1..2, fn _ ->
      assert request(sockets["deployment-b"], token(ctx, "deployment-b")).status == 200
    end)

    assert Mediator.request_count(mediator, "deployment-a") == 3
    assert Mediator.request_count(mediator, "deployment-b") == 2
  end

  test "every unmapped request shape is refused by name without forwarding", ctx do
    {_vendor, vendor_state, sockets} = refusal_fixture(ctx)
    socket = sockets["deployment-a"]

    unmapped = [
      {:get, "/v1/responses", [accept: "text/event-stream"]},
      {:post, "/v1/other", [accept: "text/event-stream"]},
      {:post, "/v1/responses", []}
    ]

    Enum.each(unmapped, fn {method, path, headers} ->
      response =
        Req.request!(
          method: method,
          url: "http://localhost#{path}",
          unix_socket: socket,
          headers: headers,
          retry: false
        )

      assert_refusal(response, 400, "unmapped_request")
    end)

    assert vendor_requests(vendor_state, "/v1/responses") == []
  end

  defp refusal_fixture(ctx, opts \\ []) do
    {vendor, vendor_state} = start_vendor(:refresh)
    {mediator, sockets} = start_mediator(ctx, vendor)

    if Keyword.get(opts, :return_mediator, false) do
      {vendor, vendor_state, sockets, mediator}
    else
      {vendor, vendor_state, sockets}
    end
  end

  defp start_vendor(mode) do
    state = start_supervised!({Agent, fn -> %{mode: mode, requests: []} end})

    vendor =
      start_supervised!(
        {Bandit, plug: {MediatorFakeVendor, owner: self(), state: state}, scheme: :http, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(vendor)
    Agent.update(state, &Map.put(&1, :url, "http://127.0.0.1:#{port}"))
    {vendor, state}
  end

  defp start_mediator(ctx, vendor) when is_pid(vendor) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(vendor)
    start_mediator(ctx, "http://127.0.0.1:#{port}")
  end

  defp start_mediator(ctx, vendor_url) do
    sockets = %{
      "deployment-a" => Path.join(ctx.root, "a.sock"),
      "deployment-b" => Path.join(ctx.root, "b.sock")
    }

    mediator =
      start_supervised!(
        {Mediator,
         deployments: sockets,
         public_key: ctx.public_key,
         credentials: %{access: "access-old", refresh: "refresh-old"},
         vendor_url: vendor_url,
         refresh_path: "/oauth/token",
         request_timeout: 500}
      )

    {mediator, sockets}
  end

  defp token(ctx, deployment_id, expires_in \\ 60) do
    Mediator.mint_token(
      deployment_id,
      System.system_time(:second) + expires_in,
      ctx.private_key
    )
  end

  defp request(socket, token) do
    Req.post!("http://localhost/v1/responses",
      unix_socket: socket,
      headers: [accept: "text/event-stream", authorization: "Bearer #{token}"],
      body: ~s({"input":"hello"}),
      retry: false
    )
  end

  defp assert_refusal(response, status, refusal) do
    assert response.status == status
    assert response.body == %{"refusal" => refusal}
  end

  defp vendor_requests(state, path) do
    Agent.get(state, &Enum.filter(&1.requests, fn request -> request.path == path end))
  end

  defp vendor_url(state), do: Agent.get(state, & &1.url)

  defp refresh_tokens(state) do
    state
    |> vendor_requests("/oauth/token")
    |> Enum.map(fn request -> request.body |> Jason.decode!() |> Map.fetch!("refresh_token") end)
  end

  defp next_message(response) do
    message =
      receive do
        message -> message
      after
        1_000 -> flunk("timed out waiting for streamed response bytes")
      end

    Req.parse_message(response, message)
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp unused_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
