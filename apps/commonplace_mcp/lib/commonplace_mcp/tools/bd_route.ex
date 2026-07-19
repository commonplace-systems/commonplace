defmodule Commonplace.MCP.Tools.BdRoute do
  @moduledoc """
  Route ticket-DAG (bd) queries to the SERVE, not the escript
  (same CX-z0v7 rationale as `Commonplace.MCP.Tools.BotRoute`).

  A single bd query (`Bd.CLI.ready`, `Bd.Frontier.compute`,
  `Bd.Issue.show`, …) fans out internally into MANY nested
  `CommitStoreClient` reads — issue listing, per-issue meta docs,
  description docs, custody-token lookups. Run naively from the escript
  each of those nested reads routes cross-node to the serve, so a single
  bd query becomes N remote round-trips and, on a degraded
  escript↔serve link, N chances to hang.

  This module makes the escript a THIN client: it does ONE
  `:rpc.call(serve, mod, fun, args)`, so the WHOLE bd query — issue
  walk, frontier compute, custody reads included — runs ON THE SERVE,
  co-located with the CommitStore/Bursar (all LOCAL calls there, fast).
  A degraded link fails ONE bounded rpc fast instead of hanging on N
  nested remote calls.

  If no serve node is configured (`remote_node/0` is `:local` — a
  non-distributed / co-located / test process), the call runs the
  target function LOCALLY. So a serve-embedded or in-test caller keeps
  working unchanged (and the bd tool tests can build a real local bd
  workspace and assert against real data), and only a real
  escript-with-a-remote-serve takes the rpc path.
  """

  alias Commonplace.Store.CommitStoreClient

  # Generous vs a healthy query but a hard fail-fast ceiling vs the
  # multi-minute hang it replaces. Overridable via app-env for slow
  # links / tests (mirrors BotRoute's `@default_rpc_timeout`).
  @default_rpc_timeout 30_000

  @doc """
  Run `mod.fun(args...)` on the serve (or locally if no serve node is
  configured). Returns whatever `mod.fun` returns, or
  `{:error, {:serve_unreachable, reason}}` if the rpc itself fails
  (timeout, node down, etc) — never blocks past the configured timeout.
  """
  @spec call(module(), atom(), [term()]) :: term()
  def call(mod, fun, args) when is_atom(mod) and is_atom(fun) and is_list(args) do
    case CommitStoreClient.remote_node() do
      :local ->
        apply(mod, fun, args)

      {:ok, node} ->
        case :rpc.call(node, mod, fun, args, rpc_timeout()) do
          {:badrpc, reason} -> {:error, {:serve_unreachable, reason}}
          result -> result
        end
    end
  end

  defp rpc_timeout do
    Application.get_env(:commonplace_mcp, :bd_rpc_timeout, @default_rpc_timeout)
  end
end
