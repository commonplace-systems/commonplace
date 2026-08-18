defmodule Commonplace.Runner.MediatorRelay do
  @moduledoc """
  Credential-free byte relay from pod loopback TCP to one bound Unix socket.

  The relay parses no successful traffic and makes no authorization or routing
  decision. If the socket cannot be opened, it emits one bounded, named HTTP
  transport failure so a TCP-only caller does not hang or lose the cause.
  """

  @unreachable_response IO.iodata_to_binary([
                          "HTTP/1.1 502 Bad Gateway\r\n",
                          "content-type: application/json\r\n",
                          "connection: close\r\n",
                          "content-length: 34\r\n\r\n",
                          ~s({"refusal":"mediator_unreachable"})
                        ])

  @doc "Start a relay linked to the caller."
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :port)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) when is_list(opts) do
    caller = self()
    ref = make_ref()
    socket_path = Keyword.fetch!(opts, :socket_path)
    port = Keyword.fetch!(opts, :port)
    pid = spawn_link(fn -> serve(socket_path, port, {caller, ref}) end)

    receive do
      {^ref, :ready} -> {:ok, pid}
      {^ref, {:error, reason}} -> {:error, reason}
    after
      2_000 -> {:error, :relay_start_timeout}
    end
  end

  @doc false
  def main([socket_path, port, ready_path]) do
    serve(socket_path, String.to_integer(port), {:file, ready_path})
  end

  @doc false
  def main_erl(args), do: args |> Enum.map(&List.to_string/1) |> main()

  defp serve(socket_path, port, ready) do
    case :gen_tcp.listen(port, [
           :binary,
           active: false,
           ip: {127, 0, 0, 1},
           packet: :raw,
           reuseaddr: true
         ]) do
      {:ok, listener} ->
        announce_ready(ready)
        accept_loop(listener, socket_path)

      {:error, reason} ->
        announce_error(ready, reason)
        exit({:relay_listen_failed, reason})
    end
  end

  defp announce_ready({:file, path}), do: File.write!(path, "ready\n")
  defp announce_ready({caller, ref}) when is_pid(caller), do: send(caller, {ref, :ready})

  defp announce_error({:file, _path}, _reason), do: :ok

  defp announce_error({caller, ref}, reason) when is_pid(caller),
    do: send(caller, {ref, {:error, reason}})

  defp accept_loop(listener, socket_path) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        owner = spawn(fn -> connection_loop(socket_path) end)
        :ok = :gen_tcp.controlling_process(client, owner)
        send(owner, {:client, client})
        accept_loop(listener, socket_path)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:relay_accept_failed, reason})
    end
  end

  defp connection_loop(socket_path) do
    receive do
      {:client, client} -> connect_upstream(client, socket_path)
    after
      1_000 -> exit(:client_handoff_timeout)
    end
  end

  defp connect_upstream(client, socket_path) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false, packet: :raw], 500) do
      {:ok, upstream} ->
        :ok = :inet.setopts(client, active: :once)
        :ok = :inet.setopts(upstream, active: :once)
        pipe(client, upstream)

      {:error, _reason} ->
        _ = :gen_tcp.send(client, @unreachable_response)
        # Half-close and drain before closing: an immediate close can tear
        # the canned refusal away before the client reads it (measured
        # 2026-08-18, ~1-in-19 under --repeat-until-failure: the client saw
        # "socket closed" instead of the 502). The shutdown flushes our
        # bytes; the bounded drain waits for the peer to finish reading.
        _ = :gen_tcp.shutdown(client, :write)
        drain_until_closed(client)
        :gen_tcp.close(client)
    end
  end

  defp drain_until_closed(socket, deadline_ms \\ 1_000) do
    case :gen_tcp.recv(socket, 0, deadline_ms) do
      {:ok, _bytes} -> drain_until_closed(socket, deadline_ms)
      {:error, _closed_or_timeout} -> :ok
    end
  end

  defp pipe(client, upstream) do
    receive do
      {:tcp, ^client, bytes} ->
        with :ok <- :gen_tcp.send(upstream, bytes),
             :ok <- :inet.setopts(client, active: :once) do
          pipe(client, upstream)
        else
          _error -> close_pair(client, upstream)
        end

      {:tcp, ^upstream, bytes} ->
        with :ok <- :gen_tcp.send(client, bytes),
             :ok <- :inet.setopts(upstream, active: :once) do
          pipe(client, upstream)
        else
          _error -> close_pair(client, upstream)
        end

      {:tcp_closed, ^client} ->
        _ = :gen_tcp.shutdown(upstream, :write)
        drain(upstream, client)

      {:tcp_closed, ^upstream} ->
        _ = :gen_tcp.shutdown(client, :write)
        drain(client, upstream)

      {:tcp_error, socket, _reason} when socket == client or socket == upstream ->
        close_pair(client, upstream)
    after
      30_000 -> close_pair(client, upstream)
    end
  end

  defp drain(open_socket, closed_socket) do
    receive do
      {:tcp, ^open_socket, bytes} ->
        _ = :gen_tcp.send(closed_socket, bytes)
        _ = :inet.setopts(open_socket, active: :once)
        drain(open_socket, closed_socket)

      {:tcp_closed, ^open_socket} ->
        close_pair(open_socket, closed_socket)

      {:tcp_error, ^open_socket, _reason} ->
        close_pair(open_socket, closed_socket)
    after
      1_000 -> close_pair(open_socket, closed_socket)
    end
  end

  defp close_pair(first, second) do
    :gen_tcp.close(first)
    :gen_tcp.close(second)
  end
end
