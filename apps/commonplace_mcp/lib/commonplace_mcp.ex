defmodule Commonplace.MCP do
  @moduledoc """
  Entry point for the `commonplace_mcp` escript.

  Bootstraps a stdio JSON-RPC 2.0 loop that acts as a Model Context
  Protocol server, exposing commonplace's Layer 2 channels surface
  (blue/red/magenta reads + writes, CLI verbs as tools) to an MCP
  client (e.g. Claude Code).

  ## Lifecycle

  1. Read the current workspace's `data_dir` (`.commonplace/`) via
     `Commonplace.CLI.find_data_dir/1`.
  2. Attempt to attach to a running `commonplace serve` via distributed
     Erlang (same mechanism the CLI uses).
  3. If no serve is running, refuse with a clear error on stderr and
     exit 1. We do not start our own CubDB because (a) two openers race
     and corrupt the store and (b) our audit events need to land on the
     same PubSub that the rest of the graph observes.
  4. Enter `Commonplace.MCP.Stdio.run_stdio/0`. Each line is parsed,
     dispatched, and the reply written to stdout.
  """

  alias Commonplace.MCP.Stdio

  def main(_argv \\ []) do
    case attach_to_serve() do
      :ok ->
        Stdio.run_stdio()
        :ok

      {:error, :not_running} ->
        IO.puts(:stderr, """
        commonplace_mcp: no running `commonplace serve` node found.

        The MCP server is a thin bridge into a running workspace — it does
        not open its own database. Start serve in the workspace you want
        the agent to participate in:

            $ commonplace serve &

        …then relaunch the MCP client.
        """)

        System.halt(1)

      {:error, {:no_workspace, cwd}} ->
        IO.puts(:stderr, """
        commonplace_mcp: no commonplace workspace found at or above:
          #{cwd}

        Run `commonplace init` to create one, or cd into an existing
        workspace before launching the MCP client.
        """)

        System.halt(1)
    end
  end

  defp attach_to_serve do
    cwd = File.cwd!()

    case Commonplace.Workspace.discover(cwd) do
      nil ->
        {:error, {:no_workspace, cwd}}

      {data_dir, _relative} ->
        serve_node = read_node_name(data_dir)

        if serve_node == nil do
          {:error, :not_running}
        else
          connect(serve_node)
        end
    end
  end

  defp read_node_name(data_dir) do
    path = Path.join(data_dir, "node_name")

    case File.read(path) do
      {:ok, content} -> content |> String.trim() |> String.to_atom()
      {:error, _} -> nil
    end
  end

  defp connect(serve_node) do
    cli_name = :"commonplace_mcp_#{:rand.uniform(999_999)}"

    case Node.start(cli_name, :shortnames) do
      {:ok, _} ->
        if Node.connect(serve_node) do
          # Route CommitStore calls through the remote node.
          Commonplace.Store.CommitStoreClient.set_remote_node(serve_node)
          :ok
        else
          Node.stop()
          {:error, :not_running}
        end

      {:error, _} ->
        {:error, :not_running}
    end
  end
end
