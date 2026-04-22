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

  alias Commonplace.MCP.{Resources, Tools}

  @protocol_version "2025-06-18"
  @server_name "commonplace-mcp"
  @server_version "0.1.0"
  @default_client_name "mcp-agent"

  defstruct initialized?: false,
            client_name: nil,
            client_version: nil,
            protocol_version: nil,
            presence_starter: nil,
            presence_stopper: nil,
            presence_info: nil

  @type presence_result :: %{required(:uuid) => String.t(), optional(any) => any}
  @type presence_starter ::
          (String.t(), atom() ->
             {:ok, presence_result()} | {:error, any()})
  @type presence_stopper :: (presence_result() -> any())

  @type t :: %__MODULE__{
          initialized?: boolean(),
          client_name: String.t() | nil,
          client_version: String.t() | nil,
          protocol_version: String.t() | nil,
          presence_starter: presence_starter() | nil,
          presence_stopper: presence_stopper() | nil,
          presence_info: presence_result() | nil
        }

  @spec new() :: t()
  def new, do: new([])

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      presence_starter: Keyword.get(opts, :presence_starter),
      presence_stopper: Keyword.get(opts, :presence_stopper)
    }
  end

  @spec initialized?(t()) :: boolean()
  def initialized?(%__MODULE__{initialized?: v}), do: v

  @spec client_name(t()) :: String.t() | nil
  def client_name(%__MODULE__{client_name: name}), do: name

  @spec presence_uuid(t()) :: String.t() | nil
  def presence_uuid(%__MODULE__{presence_info: nil}), do: nil
  def presence_uuid(%__MODULE__{presence_info: %{uuid: uuid}}), do: uuid

  @spec mailbox_uuid(t()) :: String.t() | nil
  def mailbox_uuid(%__MODULE__{presence_info: %{mailbox_uuid: uuid}}), do: uuid
  def mailbox_uuid(%__MODULE__{}), do: nil

  @spec mailbox_topic(t()) :: String.t() | nil
  def mailbox_topic(%__MODULE__{presence_info: %{mailbox_topic: topic}}), do: topic
  def mailbox_topic(%__MODULE__{}), do: nil

  @doc """
  Orderly teardown. Calls the configured presence_stopper with the
  presence_info captured at initialize (if any). Safe to call when no
  presence was started.
  """
  @spec shutdown(t()) :: :ok
  def shutdown(%__MODULE__{presence_stopper: nil}), do: :ok
  def shutdown(%__MODULE__{presence_info: nil}), do: :ok

  def shutdown(%__MODULE__{presence_stopper: stopper, presence_info: info})
      when is_function(stopper, 1) do
    _ = stopper.(info)
    :ok
  end

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
    client_name = Map.get(client, "name") || @default_client_name

    presence_info = maybe_start_presence(s.presence_starter, client_name)

    new_state = %{
      s
      | initialized?: true,
        client_name: client_name,
        client_version: Map.get(client, "version"),
        protocol_version: Map.get(params, "protocolVersion", @protocol_version),
        presence_info: presence_info
    }

    server_info =
      %{"name" => @server_name, "version" => @server_version}
      |> maybe_put("presenceUuid", presence_uuid_of(presence_info))
      |> maybe_put("mailboxUuid", mailbox_uuid_of(presence_info))
      |> maybe_put("mailboxTopic", mailbox_topic_of(presence_info))

    result = %{
      "protocolVersion" => @protocol_version,
      "serverInfo" => server_info,
      "capabilities" => %{
        "tools" => %{},
        "resources" => %{"subscribe" => false, "listChanged" => false}
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

  # --- resources/list ---
  def handle(%__MODULE__{} = s, {:request, _id, "resources/list", _params}) do
    result = %{
      "resources" => Resources.list(),
      "resourceTemplates" => Resources.templates()
    }

    {:ok, result, s}
  end

  # --- resources/read ---
  def handle(%__MODULE__{} = s, {:request, _id, "resources/read", params}) do
    params = params || %{}
    uri = Map.get(params, "uri", "")

    case Resources.read(uri) do
      {:ok, contents} ->
        {:ok, %{"contents" => contents}, s}

      {:error, :not_found} ->
        {:error, :invalid_params, "resource not found: #{uri}", s}

      {:error, reason} ->
        {:error, :internal_error, stringify(reason), s}
    end
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

  defp maybe_start_presence(nil, _name), do: nil

  defp maybe_start_presence(starter, name) when is_function(starter, 2) do
    case starter.(name, :bot) do
      {:ok, %{uuid: _} = info} -> info
      {:error, _reason} -> nil
    end
  end

  defp presence_uuid_of(nil), do: nil
  defp presence_uuid_of(%{uuid: uuid}), do: uuid

  defp mailbox_uuid_of(%{mailbox_uuid: uuid}), do: uuid
  defp mailbox_uuid_of(_), do: nil

  defp mailbox_topic_of(%{mailbox_topic: topic}), do: topic
  defp mailbox_topic_of(_), do: nil

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
