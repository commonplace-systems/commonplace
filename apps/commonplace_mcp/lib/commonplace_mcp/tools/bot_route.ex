defmodule Commonplace.MCP.Tools.BotRoute do
  @moduledoc """
  CX-z0v7 — route MUD bot calls to the SERVE, not the escript.

  Before this, `mud_send`/`mud_read` called `Commonplace.MUD.Bot`
  directly, which lazily spawned the bot's `PlayerSession` GenServer on
  the LOCAL (escript) node. Every command then fanned out into MANY
  nested `CommitStoreClient` calls that each routed cross-node to the
  serve (`set_remote_node`) — bootstrap, citizenship, look-render,
  moves. When the escript↔serve distribution link degraded, each of
  those nested remote `GenServer.call`s hung, so a single turn hung for
  minutes (Ember observed an ~8-minute stall on :5199).

  This module makes the escript a THIN client: it does ONE
  `:rpc.call(serve, Bot, fun, args)`, so the whole `Bot.send_input`
  turn — session spawn included — runs ON THE SERVE, co-located with
  the CommitStore/Bursar/PubSub (all LOCAL calls there, fast, the same
  known-good shape `CommonplaceWebWeb.MudLive` already uses for web
  players). Link degradation now fails ONE bounded rpc fast instead of
  hanging on N nested remote calls.

  ## Conditions honored (plan CX-z0v7 nod)

    * **(A) timeout-bounded** — the `:rpc.call/5` carries `@rpc_timeout`;
      a slow/broken link returns `{:badrpc, :timeout}` (surfaced as a
      legible `{:error, {:serve_unreachable, _}}`) rather than blocking
      the agent loop indefinitely.
    * **(B) own-session scope** — v1 is single-operator (one escript
      drives the sessions it names), so this is naturally satisfied.
      Scoping the RPC entry so one operator can't drive another's
      session is a named multi-operator follow-up, not a v1 blocker.
    * **(1-note) key/identity separable from session host** — running
      the session on the serve means the bot's signing identity is
      resolved against the SERVE's `SecretStore`. That's the correct
      DEFAULT for first-party agents; it does not foreclose a future
      remote-principal-signs-its-own-commits federation path.

  If no serve node is configured (`remote_node/0` is `:local` — a
  non-distributed / co-located / test process), the call runs the `Bot`
  function LOCALLY, byte-identical to the pre-CX-z0v7 behavior. So a
  serve-embedded or in-test caller keeps working unchanged, and only a
  real escript-with-a-remote-serve takes the rpc path.
  """

  alias Commonplace.MUD.Bot
  alias Commonplace.Store.CommitStoreClient

  # Generous vs a healthy turn (~2.4s serve-side incl. settle) but a hard
  # fail-fast ceiling vs the multi-minute hang it replaces. Overridable
  # via app-env for slow links / tests.
  @default_rpc_timeout 30_000

  @doc """
  Run `Bot.<fun>(args...)` on the serve (or locally if no serve node is
  configured). Returns whatever `Bot.<fun>` returns, or
  `{:error, {:serve_unreachable, reason}}` if the rpc itself fails
  (timeout, node down, etc) — never blocks past `@rpc_timeout`.
  """
  @spec call(atom(), [term()]) :: term()
  def call(fun, args) when is_atom(fun) and is_list(args) do
    case CommitStoreClient.remote_node() do
      :local ->
        apply(Bot, fun, args)

      {:ok, node} ->
        case :rpc.call(node, Bot, fun, args, rpc_timeout()) do
          {:badrpc, reason} -> {:error, {:serve_unreachable, reason}}
          result -> result
        end
    end
  end

  defp rpc_timeout do
    Application.get_env(:commonplace_mcp, :bot_rpc_timeout, @default_rpc_timeout)
  end
end
