defmodule Commonplace.Runner.Mediator do
  @moduledoc """
  Host-side custody and forwarding process for deployment-scoped vendor access.

  Each configured deployment gets one pathname Unix socket. The socket selects
  the deployment before this process verifies the independently signed,
  short-lived deployment-principal token presented on that socket.

  Tokens are the base64url encoding of exact JSON payload bytes and their
  Ed25519 signature, separated by a dot. The payload contains only
  `deployment_id` and `expires_at` (Unix seconds).
  """

  use GenServer

  alias Commonplace.Runner.MediatorPlug

  @type credentials :: %{required(:access) => String.t(), required(:refresh) => String.t()}

  @doc "Start a mediator with deployment socket paths, verifier key, and vendor credentials."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Return the number of requests that arrived on a deployment's socket."
  def request_count(mediator, deployment_id) do
    GenServer.call(mediator, {:request_count, deployment_id})
  end

  @doc "Revoke an already minted token."
  def revoke_token(mediator, token) when is_binary(token) do
    GenServer.call(mediator, {:revoke_token, token})
  end

  @doc "Mint the minimal R1 deployment-principal token."
  def mint_token(deployment_id, expires_at, private_key)
      when is_binary(deployment_id) and is_integer(expires_at) and is_binary(private_key) do
    payload = Jason.encode!(%{"deployment_id" => deployment_id, "expires_at" => expires_at})
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    encode_token_part(payload) <> "." <> encode_token_part(signature)
  end

  @doc false
  def serve(mediator, deployment_id, conn) do
    :ok = GenServer.call(mediator, {:record_request, deployment_id})

    with :ok <- mapped_request(conn),
         {:ok, token} <- bearer_token(conn),
         {:ok, token_deployment_id} <- verify_token(mediator, token),
         :ok <- same_deployment(token_deployment_id, deployment_id),
         {:ok, body, conn} <- read_entire_body(conn) do
      forward(mediator, conn, body)
    else
      {:refusal, status, name} -> refusal(conn, status, name)
    end
  end

  @impl true
  def init(opts) do
    deployments = opts |> Keyword.fetch!(:deployments) |> Map.new()
    public_key = Keyword.fetch!(opts, :public_key)
    credentials = Keyword.fetch!(opts, :credentials)
    vendor_url = opts |> Keyword.fetch!(:vendor_url) |> String.trim_trailing("/")
    refresh_path = Keyword.get(opts, :refresh_path, "/oauth/token")
    request_timeout = Keyword.get(opts, :request_timeout, 5_000)

    state = %{
      credentials: validate_credentials!(credentials),
      counts: Map.new(deployments, fn {deployment_id, _path} -> {deployment_id, 0} end),
      public_key: public_key,
      refresh_url: vendor_url <> normalize_path(refresh_path),
      request_timeout: request_timeout,
      revoked_tokens: MapSet.new(),
      vendor_url: vendor_url
    }

    listeners =
      Enum.map(deployments, fn {deployment_id, socket_path} ->
        {:ok, listener} =
          Bandit.start_link(
            plug: {MediatorPlug, mediator: self(), deployment_id: deployment_id},
            scheme: :http,
            ip: {:local, socket_path},
            port: 0,
            startup_log: false
          )

        listener
      end)

    {:ok, Map.put(state, :listeners, listeners)}
  end

  @impl true
  def handle_call({:request_count, deployment_id}, _from, state) do
    {:reply, Map.get(state.counts, deployment_id, 0), state}
  end

  def handle_call({:record_request, deployment_id}, _from, state) do
    counts = Map.update(state.counts, deployment_id, 1, &(&1 + 1))
    {:reply, :ok, %{state | counts: counts}}
  end

  def handle_call({:revoke_token, token}, _from, state) do
    {:reply, :ok, %{state | revoked_tokens: MapSet.put(state.revoked_tokens, token)}}
  end

  def handle_call({:verify_token, token}, _from, state) do
    result =
      cond do
        MapSet.member?(state.revoked_tokens, token) ->
          {:refusal, 401, "revoked_token"}

        true ->
          verify_signed_token(token, state.public_key)
      end

    {:reply, result, state}
  end

  def handle_call({:access_token}, _from, state) do
    {:reply, state.credentials.access, state}
  end

  def handle_call(:request_config, _from, state) do
    {:reply, Map.take(state, [:request_timeout, :vendor_url]), state}
  end

  def handle_call({:refresh, attempted_access}, _from, state) do
    if state.credentials.access == attempted_access do
      case request_refresh(state) do
        {:ok, credentials} ->
          {:reply, {:ok, credentials.access}, %{state | credentials: credentials}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:ok, state.credentials.access}, state}
    end
  end

  defp mapped_request(%Plug.Conn{method: "POST", request_path: "/v1/responses"} = conn) do
    if "text/event-stream" in Plug.Conn.get_req_header(conn, "accept") do
      :ok
    else
      {:refusal, 404, "unmapped_request"}
    end
  end

  defp mapped_request(_conn), do: {:refusal, 404, "unmapped_request"}

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _other -> {:refusal, 400, "invalid_token"}
    end
  end

  defp verify_token(mediator, token), do: GenServer.call(mediator, {:verify_token, token})

  defp verify_signed_token(token, public_key) do
    with [encoded_payload, encoded_signature] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- decode_token_part(encoded_payload),
         {:ok, signature} <- decode_token_part(encoded_signature),
         true <- :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]),
         {:ok, %{"deployment_id" => deployment_id, "expires_at" => expires_at}} <-
           Jason.decode(payload),
         true <- is_binary(deployment_id) and is_integer(expires_at) do
      if expires_at > System.system_time(:second) do
        {:ok, deployment_id}
      else
        {:refusal, 403, "expired_token"}
      end
    else
      _other -> {:refusal, 400, "invalid_token"}
    end
  rescue
    ArgumentError -> {:refusal, 400, "invalid_token"}
  end

  defp same_deployment(deployment_id, deployment_id), do: :ok
  defp same_deployment(_token_id, _socket_id), do: {:refusal, 409, "identity_mismatch"}

  defp read_entire_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([body | acc])), conn}
      {:more, body, conn} -> read_entire_body(conn, [body | acc])
      {:error, _reason} -> {:refusal, 400, "invalid_request"}
    end
  end

  defp forward(mediator, conn, body) do
    access = GenServer.call(mediator, {:access_token})

    case vendor_request(mediator, conn, body, access) do
      {:ok, %Req.Response{status: 401} = response} ->
        Req.cancel_async_response(response)

        case GenServer.call(mediator, {:refresh, access}) do
          {:ok, refreshed_access} -> retry_after_refresh(mediator, conn, body, refreshed_access)
          {:error, :unreachable} -> refusal(conn, 424, "vendor_unreachable")
          {:error, _reason} -> refusal(conn, 422, "vendor_unauthorized")
        end

      {:ok, response} ->
        stream_response(conn, response)

      {:error, _reason} ->
        refusal(conn, 424, "vendor_unreachable")
    end
  end

  defp retry_after_refresh(mediator, conn, body, access) do
    case vendor_request(mediator, conn, body, access) do
      {:ok, %Req.Response{status: 401} = response} ->
        Req.cancel_async_response(response)
        refusal(conn, 422, "vendor_unauthorized")

      {:ok, response} ->
        stream_response(conn, response)

      {:error, _reason} ->
        refusal(conn, 424, "vendor_unreachable")
    end
  end

  defp vendor_request(mediator, conn, body, access) do
    %{request_timeout: timeout, vendor_url: vendor_url} =
      GenServer.call(mediator, :request_config)

    # PROMPT EXFILTRATION IS NOT SOLVED: a mediator is a bidirectional channel
    # and cannot judge prompt content. That residual is accepted and named here.
    Req.post(vendor_url <> "/v1/responses",
      body: body,
      headers: forwarded_headers(conn, access),
      into: :self,
      raw: true,
      decode_body: false,
      retry: false,
      receive_timeout: timeout,
      connect_options: [timeout: timeout]
    )
  end

  defp forwarded_headers(conn, access) do
    content_type = Plug.Conn.get_req_header(conn, "content-type")

    [
      {"accept", "text/event-stream"},
      {"authorization", "Bearer #{access}"}
    ] ++ Enum.map(content_type, &{"content-type", &1})
  end

  defp stream_response(conn, %Req.Response{} = response) do
    conn =
      case Req.Response.get_header(response, "content-type") do
        [content_type | _rest] -> Plug.Conn.put_resp_header(conn, "content-type", content_type)
        [] -> conn
      end

    conn = Plug.Conn.send_chunked(conn, response.status)

    Enum.reduce_while(response.body, conn, fn bytes, streaming_conn ->
      case Plug.Conn.chunk(streaming_conn, bytes) do
        {:ok, streaming_conn} -> {:cont, streaming_conn}
        {:error, _reason} -> {:halt, streaming_conn}
      end
    end)
  end

  defp refusal(conn, status, name) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"refusal" => name}))
  end

  defp request_refresh(state) do
    case Req.post(state.refresh_url,
           json: %{refresh_token: state.credentials.refresh},
           retry: false,
           receive_timeout: state.request_timeout,
           connect_options: [timeout: state.request_timeout]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        refreshed_credentials(body, state.credentials.refresh)

      {:ok, _response} ->
        {:error, :refresh_refused}

      {:error, _reason} ->
        {:error, :unreachable}
    end
  end

  defp refreshed_credentials(body, old_refresh) when is_map(body) do
    access = Map.get(body, "access_token") || Map.get(body, :access_token)
    refresh = Map.get(body, "refresh_token") || Map.get(body, :refresh_token) || old_refresh

    if is_binary(access) and is_binary(refresh) do
      {:ok, %{access: access, refresh: refresh}}
    else
      {:error, :invalid_refresh_response}
    end
  end

  defp refreshed_credentials(_body, _old_refresh), do: {:error, :invalid_refresh_response}

  defp validate_credentials!(%{access: access, refresh: refresh})
       when is_binary(access) and is_binary(refresh),
       do: %{access: access, refresh: refresh}

  defp validate_credentials!(_credentials) do
    raise ArgumentError, "credentials must contain binary :access and :refresh values"
  end

  defp normalize_path("/" <> _rest = path), do: path
  defp normalize_path(path), do: "/" <> path

  defp encode_token_part(bytes), do: Base.url_encode64(bytes, padding: false)
  defp decode_token_part(encoded), do: Base.url_decode64(encoded, padding: false)
end
