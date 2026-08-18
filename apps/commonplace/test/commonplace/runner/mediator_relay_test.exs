defmodule Commonplace.Runner.MediatorRelayTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.{Mediator, MediatorRelay}
  alias Commonplace.Test.MediatorFakeVendor

  setup do
    root = Path.join(System.tmp_dir!(), "mediator_r2_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {public_key, private_key} = Signing.generate_keypair()
    state = start_supervised!({Agent, fn -> %{mode: :refresh, requests: []} end})

    vendor =
      start_supervised!(
        {Bandit, plug: {MediatorFakeVendor, owner: self(), state: state}, scheme: :http, port: 0}
      )

    {:ok, {_ip, vendor_port}} = ThousandIsland.listener_info(vendor)
    Agent.update(state, &Map.put(&1, :url, "http://127.0.0.1:#{vendor_port}"))

    sockets = %{
      "deployment-a" => Path.join(root, "a.sock"),
      "deployment-b" => Path.join(root, "b.sock")
    }

    mediator =
      start_supervised!(
        {Mediator,
         deployments: sockets,
         public_key: public_key,
         credentials: %{access: "access-old", refresh: "refresh-old"},
         vendor_url: "http://127.0.0.1:#{vendor_port}",
         request_timeout: 500}
      )

    %{
      mediator: mediator,
      private_key: private_key,
      sockets: sockets,
      root: root,
      vendor_state: state
    }
  end

  test "relay is a bidirectional byte pipe and surgical revocation names only deployment A",
       ctx do
    port_a = unused_tcp_port()
    port_b = unused_tcp_port()

    start_supervised!({MediatorRelay, socket_path: ctx.sockets["deployment-a"], port: port_a})
    start_supervised!({MediatorRelay, socket_path: ctx.sockets["deployment-b"], port: port_b})

    token_a = token(ctx, "deployment-a")
    token_b = token(ctx, "deployment-b")

    assert request(port_a, token_a).status == 200
    assert request(port_b, token_b).status == 200

    :ok = Mediator.revoke_token(ctx.mediator, token_a)

    assert %{status: 400, body: %{"refusal" => "revoked_token"}} = request(port_a, token_a)
    assert request(port_b, token_b).status == 200
  end

  test "mediator death returns a named relay failure within a bounded time", ctx do
    port = unused_tcp_port()
    start_supervised!({MediatorRelay, socket_path: ctx.sockets["deployment-a"], port: port})
    GenServer.stop(ctx.mediator)

    task = Task.async(fn -> request(port, token(ctx, "deployment-a")) end)

    assert %{status: 502, body: %{"refusal" => "mediator_unreachable"}} =
             Task.await(task, 2_000)
  end

  defp token(ctx, deployment_id) do
    Mediator.mint_token(deployment_id, System.system_time(:second) + 60, ctx.private_key)
  end

  defp request(port, token) do
    Req.post!("http://127.0.0.1:#{port}/v1/responses",
      headers: [accept: "text/event-stream", authorization: "Bearer #{token}"],
      body: ~s({"input":"hello"}),
      retry: false
    )
  end

  defp unused_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
