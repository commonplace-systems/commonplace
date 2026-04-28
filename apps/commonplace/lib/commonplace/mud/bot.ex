defmodule Commonplace.MUD.Bot do
  @moduledoc """
  Bot session management for the MUD MCP bridge (CX-yu2w).

  Bots play the MUD without going through the CLI's `mud connect` path.
  Each bot is identified by a name (the same `.usr` honorific shape as
  human players); a long-lived buffered PlayerSession is spawned on
  first input and reused thereafter, so subscriptions persist between
  MCP tool calls.

  Public API is two functions: `send_input/2` (sends a line, drains and
  returns events) and `read_events/1` (drains pending events without
  sending input — useful for ambient observation between commands).

  Sessions are registered globally on `{:global, {__MODULE__, name}}`
  so all MCP / CLI nodes in a cluster see the same bot session
  (matches MoveServer / TickBot's clustering choice).
  """

  alias Commonplace.MUD.{Bootstrap, PlayerSession}
  alias Commonplace.Store.CommitStoreClient

  @type event :: %{optional(atom) => any}

  @default_settle_ms 50

  @doc """
  Send `line` to bot `name`'s session. Returns
  `{:ok, [event]}` where each event is the structured map output by
  PlayerSession (kind/who/text/etc — see PlayerSession.render_event for
  what's typically rendered).

  Spawns the session lazily on first call.
  """
  @spec send_input(String.t(), String.t(), keyword()) :: {:ok, [event]} | {:error, term()}
  def send_input(name, line, opts \\ []) do
    settle = Keyword.get(opts, :settle_ms, @default_settle_ms)

    with {:ok, session} <- ensure_session(name, opts) do
      :ok = PlayerSession.input_sync(session, line)
      Process.sleep(settle)
      {:ok, PlayerSession.drain_buffer(session)}
    end
  end

  @doc """
  Drain pending events for bot `name` without sending input. Spawns the
  session on first call (so the bot starts subscribing).
  """
  @spec read_events(String.t(), keyword()) :: {:ok, [event]} | {:error, term()}
  def read_events(name, opts \\ []) do
    with {:ok, session} <- ensure_session(name, opts) do
      {:ok, PlayerSession.drain_buffer(session)}
    end
  end

  @doc """
  Stop a bot's session. Useful for tests; in production the session
  lives until the OTP supervisor shuts it down.
  """
  def stop(name) do
    case lookup(name) do
      {:ok, pid} -> PlayerSession.stop(pid)
      :error -> :ok
    end
  end

  ## Internals

  defp ensure_session(name, opts) do
    case lookup(name) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        spawn_session(name, opts)
    end
  end

  defp lookup(name) do
    case :global.whereis_name({__MODULE__, name}) do
      :undefined -> :error
      pid when is_pid(pid) -> if Process.alive?(pid), do: {:ok, pid}, else: :error
    end
  end

  defp spawn_session(name, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    root_uuid = Keyword.get_lazy(opts, :root_uuid, &resolve_root/0)

    case root_uuid do
      nil ->
        {:error, :no_workspace_root}

      root ->
        # Idempotently ensure the demo world exists before any session
        # spawns — otherwise PlayerSession's stub fallback wins and
        # the bot lands in a featureless start room.
        Bootstrap.seed(root, store)

        # The PlayerSession globally registers itself by name.
        global_name = {:global, {__MODULE__, name}}

        result =
          GenServer.start(
            PlayerSession,
            [
              player_name: name,
              root_uuid: root,
              store: store,
              buffered: true
            ],
            name: global_name
          )

        case result do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          err -> err
        end
    end
  end

  defp resolve_root do
    case Commonplace.Workspace.root_uuid() do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end
end
