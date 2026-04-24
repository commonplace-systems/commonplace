defmodule Commonplace.MCP.AnubisServer do
  @moduledoc """
  MCP server backed by `anubis_mcp` (CX-hf71).

  Replaces the hand-rolled `Commonplace.MCP.{Server, Stdio, Protocol}`
  layers from the pre-CX-hf71 code. Tool and resource registration stays
  routed through the existing `Commonplace.MCP.Tools` / `Resources`
  modules — this server translates anubis's `handle_request/2` dispatch
  into the same call surface those modules already expose.

  ## Presence + mailbox bootstrap (CX-92u, CX-voi)

  Anubis calls `init/2` AFTER the initialize handshake completes
  (post `notifications/initialized`). That's where we spawn the
  `Commonplace.Presence.Server` and the per-agent mailbox onramp, then
  stash the three identifiers (presence_uuid, mailbox_uuid,
  mailbox_topic) into `frame.assigns`. The `presence_info` tool reads
  them back.

  ### Wire contract break

  The pre-CX-hf71 server put `presenceUuid` / `mailboxUuid` /
  `mailboxTopic` in the `initialize` response's `serverInfo`. Anubis's
  hard-coded initialize handler doesn't let us enrich that payload.
  Clients now call `tools/call presence_info` (snake_case keys) after
  initialization instead. CX-xaof removes the hand-rolled substrate
  once this path has proven itself.

  ## Shutdown

  `terminate/2` invokes the configured `presence_stopper` (same
  signature as the hand-rolled server) so mailbox onramps commit
  their tail events and `.bot` presence files are removed before the
  escript exits.
  """

  use Anubis.Server,
    name: "commonplace-mcp",
    version: "0.2.0",
    capabilities: [:tools, :resources]

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Commonplace.MCP.{Resources, Tools}

  @doc """
  Build a configuration for starting the server under a supervisor.

  Accepts:
    * `:presence_starter` — `(String.t(), atom() -> {:ok, map} | {:error, term})`
    * `:presence_stopper` — `(map -> any)`

  These are stored in a per-session agent keyed by pid so `init/2` and
  `terminate/2` can reach them. Pattern mirrors the hand-rolled
  `Commonplace.MCP.Server.new/1` injection surface so the escript's
  existing presence-bootstrap closures drop in unchanged.
  """
  def config(opts \\ []) do
    starter = Keyword.get(opts, :presence_starter)
    stopper = Keyword.get(opts, :presence_stopper)

    # Store hooks in :persistent_term under a per-process key so each
    # init/terminate callback can find them. A keyed Agent would work
    # too, but persistent_term keeps the module stateless and matches
    # how CommitStoreClient.set_remote_node distributes per-node state.
    :persistent_term.put({__MODULE__, :presence_starter}, starter)
    :persistent_term.put({__MODULE__, :presence_stopper}, stopper)
    :ok
  end

  @impl Anubis.Server
  def init(client_info, frame) do
    client_name = Map.get(client_info, "name") || "mcp-agent"

    starter = :persistent_term.get({__MODULE__, :presence_starter}, nil)

    frame =
      case starter && starter.(client_name, :bot) do
        {:ok, %{} = info} ->
          frame
          |> Frame.assign(:presence_info, info)
          |> Frame.assign(:presence_uuid, Map.get(info, :uuid))
          |> Frame.assign(:mailbox_uuid, Map.get(info, :mailbox_uuid))
          |> Frame.assign(:mailbox_topic, Map.get(info, :mailbox_topic))

        _ ->
          frame
      end

    {:ok, frame}
  end

  @impl Anubis.Server
  def terminate(_reason, frame) do
    stopper = :persistent_term.get({__MODULE__, :presence_stopper}, nil)

    case {stopper, frame.assigns[:presence_info]} do
      {stopper, %{} = info} when is_function(stopper, 1) -> stopper.(info)
      _ -> :ok
    end
  end

  @impl Anubis.Server
  def handle_request(%{"method" => "tools/list"}, frame) do
    {:reply, %{"tools" => Tools.list()}, frame}
  end

  def handle_request(%{"method" => "tools/call", "params" => params}, frame) do
    name = Map.get(params || %{}, "name")
    args = Map.get(params || %{}, "arguments", %{})
    context = presence_context(frame)

    case Tools.call(name, args, context) do
      {:ok, result} ->
        {:reply, result, frame}

      {:error, :not_found} ->
        {:error, Error.protocol(:method_not_found, %{method: name}), frame}

      {:error, :invalid_params, detail} ->
        {:error, Error.protocol(:invalid_params, %{message: detail}), frame}

      {:error, reason} ->
        {:error, Error.execution(stringify(reason)), frame}
    end
  end

  def handle_request(%{"method" => "resources/list"}, frame) do
    result = %{
      "resources" => Resources.list(),
      "resourceTemplates" => Resources.templates()
    }

    {:reply, result, frame}
  end

  def handle_request(%{"method" => "resources/read", "params" => params}, frame) do
    uri = Map.get(params || %{}, "uri", "")

    case Resources.read(uri) do
      {:ok, contents} ->
        {:reply, %{"contents" => contents}, frame}

      {:error, :not_found} ->
        {:error, Error.resource(:not_found, %{uri: uri}), frame}

      {:error, reason} ->
        {:error, Error.execution(stringify(reason)), frame}
    end
  end

  def handle_request(%{"method" => method}, frame) do
    {:error, Error.protocol(:method_not_found, %{method: method}), frame}
  end

  defp presence_context(frame) do
    %{
      presence_uuid: frame.assigns[:presence_uuid],
      mailbox_uuid: frame.assigns[:mailbox_uuid],
      mailbox_topic: frame.assigns[:mailbox_topic]
    }
  end

  defp stringify(reason) when is_binary(reason), do: reason
  defp stringify(reason), do: inspect(reason)
end
