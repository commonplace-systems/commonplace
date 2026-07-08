defmodule Commonplace.MCP.Tools.BotRouteTest do
  @moduledoc """
  CX-z0v7: the escript→serve rpc boundary must FAIL FAST (condition A) —
  an unreachable serve returns a legible `{:serve_unreachable, _}` rather
  than hanging the agent loop, which is the whole point of moving the Bot
  onto the serve behind one bounded rpc.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MCP.Tools.BotRoute
  alias Commonplace.Store.CommitStoreClient

  test "routes to the serve and fails fast with {:serve_unreachable, _} when it's unreachable" do
    CommitStoreClient.set_remote_node(:"cx_z0v7_nonexistent@nowhere")
    on_exit(fn -> CommitStoreClient.clear_remote_node() end)

    # A bogus serve node -> :rpc.call returns {:badrpc, :nodedown}, surfaced
    # as {:error, {:serve_unreachable, _}} without blocking on N nested calls.
    assert {:error, {:serve_unreachable, _}} = BotRoute.call(:read_events, ["nobody"])
  end
end
