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

  ## Signing identity (CX-5plk)

  MCP MUD sessions have no browser/CLI login, so without this a bot's
  writes carried no `SigningContext` at all — unsigned, and DENIED by
  the trust gate on a strict+enforce node (`PlayerSession`'s
  `opts[:player_identity_uuid]` seam, built by CX-lg06, was simply
  never fed anything here). `spawn_session/2` now resolves a per-bot
  identity keyed by the bot's NAME — the same `.usr` presence handle —
  via `Commonplace.Presence.Identity.register_agent/4` (a `:bot` cold
  identity, extension `.bot`, so it can never collide with the bot's
  own `.usr` presence file that `PlayerSession.find_presence/3` walks
  for) and threads the resulting `player_identity_uuid` into the
  `PlayerSession` start opts, which the CX-lg06 seam already consumes.

  `register_agent/4` and `Commonplace.Crypto.AgentKeys.ensure/2` are
  both idempotent (look up the existing cold identity / keypair before
  minting), so the same bot name always resolves to the same
  identity_uuid and the same keypair — across repeated `send_input`
  calls AND across a session restart (`Bot.stop/1` then a fresh
  `send_input`) — no new key is ever minted for a name that already has
  one, and custody lives in the node-local `SecretStore` (or
  `opts[:secret_store]`, for test isolation).

  Someone has to sign the bot's own registration commits (the identity
  doc + the `__identities__` schema entry) — there is no human operator
  in the loop for an MCP session, so this uses
  `Commonplace.Crypto.NodeIdentity.signing_context/0`, the sanctioned
  headless fallback (D9's "node signs" branch — `Trust` auto-trusts the
  node's own identity, so this works out of the box on a fresh strict
  workspace). Callers that want a specific registrar (tests pinning a
  deterministic root identity) can override with
  `opts[:registrar_signing_context]`. If identity resolution fails for
  any reason, `spawn_session/2` degrades gracefully to the pre-existing
  unsigned behavior — a bot session is still better than none, and this
  keeps permissive-node dogfooding unaffected either way.

  **FLAG — signing alone is not enough to PLAY under strict+enforce.**
  A freshly-signed bot with no capability cert is still denied by the
  trust gate's capability check on docs it doesn't own (see
  `Commonplace.MUD.SignedWrite` / `PlayerSessionIdentityTest`'s "y"
  player for the shape of that denial). Provisioning a bot a starter
  cert (e.g. auto-issuing a section cert over its start room, or
  spawning it into a room it already owns) is a separate follow-on,
  deliberately NOT built here.
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.MUD.{Bootstrap, PlayerSession}
  alias Commonplace.Presence.Identity
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

        identity_opts = resolve_signing_opts(name, root, store, opts)

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
            ] ++ identity_opts,
            name: global_name
          )

        case result do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          err -> err
        end
    end
  end

  # CX-5plk: resolve (idempotently register, if needed) a per-bot
  # signing identity and return the `PlayerSession` start opts that
  # thread it through the CX-lg06 seam. `[]` (unsigned, legacy
  # behavior) on any resolution failure — a bot that can't be signed
  # is still better than no bot at all.
  defp resolve_signing_opts(name, root, store, opts) do
    secret_store = Keyword.get(opts, :secret_store, Commonplace.Store.SecretStore)
    registrar_opts = [secret_store: secret_store] ++ registrar_signing_opts(opts)

    case Identity.register_agent(name, root, store, registrar_opts) do
      {:ok, identity_uuid, _pub} ->
        [player_identity_uuid: identity_uuid, secret_store: secret_store]

      {:error, _reason} ->
        []
    end
  end

  # The principal that signs the bot's own registration commits (D9).
  # Tests may pin a deterministic root/operator identity via
  # `opts[:registrar_signing_context]`; production headless spawns fall
  # back to the node's own signing identity (the sanctioned D9
  # headless branch — `Trust` auto-trusts it). Neither available —
  # unsigned registration commits (matches the pre-CX-5plk behavior).
  defp registrar_signing_opts(opts) do
    case Keyword.get(opts, :registrar_signing_context) do
      nil ->
        case NodeIdentity.signing_context() do
          {:ok, ctx} -> [signing_context: ctx]
          {:error, _} -> []
        end

      ctx ->
        [signing_context: ctx]
    end
  end

  defp resolve_root do
    case Commonplace.Workspace.root_uuid() do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end
end
