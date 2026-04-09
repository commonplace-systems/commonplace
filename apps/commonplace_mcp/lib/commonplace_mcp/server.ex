defmodule Commonplace.MCP.Server do
  @moduledoc """
  Dispatch layer for the commonplace MCP server.

  A `%Server{}` value holds the handshake state (initialized?, client name,
  etc.) and routes parsed `Protocol` requests to the right handler. It is
  intentionally a plain struct, not a GenServer: the stdio loop owns it as
  a local variable and threads updated copies through each message.

  ## handle/2 return shapes

    * `{:ok, result, server}`          — reply to a request with this result
    * `{:error, kind, server}`         — reply with a protocol error of the
                                          given kind (same tags as
                                          `Protocol.encode_response/2`)
    * `{:error, kind, detail, server}` — same, with a detail string
    * `{:noreply, server}`             — the message was a notification; no
                                          reply, just an updated state
  """

  alias Commonplace.MCP.Tools

  @protocol_version "2025-06-18"
  @server_name "commonplace-mcp"
  @server_version "0.1.0"

  defstruct initialized?: false,
            client_name: nil,
            client_version: nil,
            protocol_version: nil

  @type t :: %__MODULE__{
          initialized?: boolean(),
          client_name: String.t() | nil,
          client_version: String.t() | nil,
          protocol_version: String.t() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec initialized?(t()) :: boolean()
  def initialized?(%__MODULE__{initialized?: v}), do: v

  @spec client_name(t()) :: String.t() | nil
  def client_name(%__MODULE__{client_name: name}), do: name

  @type request :: {:request, term(), String.t(), map() | nil}
  @type notification :: {:notification, String.t(), map() | nil}

  @spec handle(t(), request() | notification()) ::
          {:ok, any(), t()}
          | {:error, atom(), t()}
          | {:error, atom(), String.t(), t()}
          | {:noreply, t()}

  # --- initialize: always allowed ---
  def handle(%__MODULE__{} = s, {:request, _id, "initialize", params}) do
    params = params || %{}
    client = Map.get(params, "clientInfo", %{})

    new_state = %{
      s
      | initialized?: true,
        client_name: Map.get(client, "name"),
        client_version: Map.get(client, "version"),
        protocol_version: Map.get(params, "protocolVersion", @protocol_version)
    }

    result = %{
      "protocolVersion" => @protocol_version,
      "serverInfo" => %{"name" => @server_name, "version" => @server_version},
      "capabilities" => %{
        "tools" => %{},
        "resources" => %{}
      }
    }

    {:ok, result, new_state}
  end

  # --- anything else before initialize is rejected ---
  def handle(%__MODULE__{initialized?: false} = s, {:request, _id, _method, _params}) do
    {:error, :invalid_request, s}
  end

  # --- tools/list ---
  def handle(%__MODULE__{} = s, {:request, _id, "tools/list", _params}) do
    result = %{"tools" => Tools.list()}
    {:ok, result, s}
  end

  # --- tools/call ---
  def handle(%__MODULE__{} = s, {:request, _id, "tools/call", params}) do
    params = params || %{}
    name = Map.get(params, "name")
    args = Map.get(params, "arguments", %{})

    case Tools.call(name, args) do
      {:ok, result} ->
        {:ok, result, s}

      {:error, :not_found} ->
        {:error, :method_not_found, name, s}

      {:error, :invalid_params, detail} ->
        {:error, :invalid_params, detail, s}

      {:error, reason} ->
        {:error, :internal_error, stringify(reason), s}
    end
  end

  # --- unknown method ---
  def handle(%__MODULE__{} = s, {:request, _id, method, _params}) do
    {:error, :method_not_found, method, s}
  end

  # --- notifications/initialized (acknowledge) ---
  def handle(%__MODULE__{} = s, {:notification, "notifications/initialized", _params}) do
    {:noreply, s}
  end

  # --- other notifications: ignore silently ---
  def handle(%__MODULE__{} = s, {:notification, _method, _params}) do
    {:noreply, s}
  end

  defp stringify(reason) when is_binary(reason), do: reason
  defp stringify(reason), do: inspect(reason)
end
