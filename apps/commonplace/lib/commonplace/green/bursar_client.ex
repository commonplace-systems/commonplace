defmodule Commonplace.Green.BursarClient do
  @moduledoc """
  The dispatch seam in front of `Commonplace.Green.Bursar` — the same
  pattern as `Commonplace.Store.CommitStoreClient`, for the same reason.

  The Bursar's token table is GenServer memory, so cluster-wide mutual
  exclusion requires exactly one Bursar per cluster. Rather than electing
  one (that's R7's cluster-arbiter question, deferred), the Bursar rides
  the CommitStore's existing single-owner *designation*: it starts only
  on the serve node (`:bursar_on_boot`), and every other node reaches it
  the same way it reaches the store — `CommitStoreClient.remote_node/0`'s
  node-wide `:persistent_term`, set once at CLI/MCP bootstrap. Remote
  dispatch is `GenServer.call({Bursar, node}, ...)`: synchronous
  grant/deny over BEAM distribution, zero `:global`, zero new protocol.

  **Fail-closed (`{:error, :bursar_unavailable}`).** When no Bursar is
  reachable — no local process, serve down, node disconnected — every
  call returns `{:error, :bursar_unavailable}` instead of exiting. This
  is the safety posture move #4 exists for: a bare-`mix run` temp node
  that boots the app has a TickBot but no Bursar route, so it can never
  acquire the tick lease (it idles) and `World.move` denies rather than
  moving unlocked. No lock service ⇒ no mutation, never "assume free."

  Like `CommitStoreClient`, callers may alias this module as the
  `server` argument; it is normalized back to the real `Bursar` name.
  """

  alias Commonplace.Green.Bursar
  alias Commonplace.Store.CommitStoreClient

  @doc "Acquire an exclusive token. See `Bursar.acquire/4`."
  def acquire(server \\ Bursar, path, holder, opts \\ []) do
    safe(fn -> Bursar.acquire(route(server), path, holder, opts) end)
  end

  @doc "Release a held token. See `Bursar.release/3`."
  def release(server \\ Bursar, path, holder) do
    safe(fn -> Bursar.release(route(server), path, holder) end)
  end

  @doc "Query token status. See `Bursar.query/2`."
  def query(server \\ Bursar, path) do
    safe(fn -> Bursar.query(route(server), path) end)
  end

  @doc "List all held tokens. See `Bursar.list_tokens/1`."
  def list_tokens(server \\ Bursar) do
    safe(fn -> Bursar.list_tokens(route(server)) end)
  end

  @doc "Force-release a token (admin). See `Bursar.force_release/2`."
  def force_release(server \\ Bursar, path) do
    safe(fn -> Bursar.force_release(route(server), path) end)
  end

  @doc "Transfer a held token to a new holder. See `Bursar.transfer/4`."
  def transfer(server \\ Bursar, path, from_holder, to_holder) do
    safe(fn -> Bursar.transfer(route(server), path, from_holder, to_holder) end)
  end

  @doc "Renew (keep-alive) a held token. See `Bursar.renew/4`."
  def renew(server \\ Bursar, path, holder, opts \\ []) do
    safe(fn -> Bursar.renew(route(server), path, holder, opts) end)
  end

  # Remote mode routes to the serve node's locally-named Bursar — a
  # `{name, node}` ref, which GenServer.call dispatches over distribution
  # (the CX-o3r7 / CommitStoreClient precedent). Local mode uses the
  # caller's server arg, normalizing the alias-this-module idiom.
  defp route(server) do
    case CommitStoreClient.remote_node() do
      {:ok, node} -> {Bursar, node}
      :local -> normalize(server)
    end
  end

  defp normalize(__MODULE__), do: Bursar
  defp normalize(server), do: server

  # :exit covers noproc (no bursar started), timeout, and nodedown —
  # all collapse to the same caller-visible fact: no lock authority
  # reachable, so deny.
  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :bursar_unavailable}
  end
end
