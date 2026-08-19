defmodule Commonplace.MCP.WorkspaceVerifyTest do
  @moduledoc """
  CX-fml6 (discovery half), Part 2: `Commonplace.MCP.compare_workspace/2`
  is the pure comparison at the heart of `verify_same_workspace/2` —
  extracted so it's testable without distributed Erlang / RPC. The
  2026-07-10 incident that motivates this check: discovery pinned to an
  orphan serve node running from a DIFFERENT data dir (dogfood-mud), and
  the escript RPC'd its work into the wrong workspace. A mismatch here
  must be treated as positive evidence of the wrong target; "couldn't
  determine" (nil on either side) must NOT be conflated with "matches."
  """
  use ExUnit.Case, async: true

  alias Commonplace.MCP

  test "equal paths → :ok" do
    assert MCP.compare_workspace("/home/jes/ws", "/home/jes/ws") == :ok
  end

  test "trailing-slash difference → :ok (Path.expand normalizes)" do
    assert MCP.compare_workspace("/home/jes/ws/", "/home/jes/ws") == :ok
  end

  test "relative vs absolute, same resolved location → :ok" do
    cwd = File.cwd!()
    relative = "."
    assert MCP.compare_workspace(cwd, relative) == :ok
  end

  test "nil remote → workspace_unverifiable, not a match" do
    assert MCP.compare_workspace(nil, "/home/jes/ws") ==
             {:error, {:workspace_unverifiable, "remote data_dir is nil"}}
  end

  test "nil local → workspace_unverifiable, not a match" do
    assert MCP.compare_workspace("/home/jes/ws", nil) ==
             {:error, {:workspace_unverifiable, "local data_dir is nil"}}
  end

  test "genuine mismatch → workspace_mismatch with both dirs" do
    assert MCP.compare_workspace("/home/jes/dogfood-mud", "/home/jes/ws") ==
             {:error, {:workspace_mismatch, "/home/jes/dogfood-mud", "/home/jes/ws"}}
  end

  test "unexpected remote shape (not a binary, not nil) → workspace_unverifiable" do
    assert {:error, {:workspace_unverifiable, _}} =
             MCP.compare_workspace(:not_a_path, "/home/jes/ws")
  end
end
