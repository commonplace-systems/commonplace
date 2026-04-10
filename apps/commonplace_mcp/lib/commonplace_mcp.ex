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

  alias Commonplace.MCP.{Server, Stdio}
  alias Commonplace.Presence.Server, as: PresenceServer

  def main(_argv \\ []) do
    case attach_to_serve() do
      {:ok, root_uuid} ->
        server =
          Server.new(
            presence_starter: presence_starter(root_uuid),
            presence_stopper: presence_stopper(root_uuid)
          )

        Stdio.run_stdio(server)
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

      {:error, :no_root} ->
        IO.puts(:stderr, """
        commonplace_mcp: workspace found but no root UUID set.

        This workspace is half-initialized. Run `commonplace init` or
        restore from backup.
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

        cond do
          serve_node == nil ->
            {:error, :not_running}

          true ->
            with :ok <- connect(serve_node),
                 {:ok, root_uuid} <- read_root_uuid(data_dir) do
              # Propagate the discovered data_dir into the escript's
              # Application env so helpers that default to it
              # (e.g. Commonplace.Workspace.root_uuid/0) see the
              # workspace path rather than the "data" fallback. Needed
              # for any ViewActionDispatch path that runs in the
              # escript's process and touches workspace-scoped state.
              Application.put_env(:commonplace, :data_dir, data_dir)
              {:ok, root_uuid}
            end
        end
    end
  end

  defp read_root_uuid(data_dir) do
    case File.read(Path.join(data_dir, "root")) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, _} -> {:error, :no_root}
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

  # Build a presence_starter function compatible with Server.new.
  # Spawns a Presence.Server rooted at `root_uuid`, and broadcasts a
  # presence.enter event on the containing dir's magenta topic.
  defp presence_starter(root_uuid) do
    fn name, type ->
      case PresenceServer.start_link(
             name: name,
             type: type,
             dir_uuid: root_uuid,
             store: Commonplace.Store.CommitStoreClient
           ) do
        {:ok, pid} ->
          uuid = PresenceServer.uuid(pid)
          broadcast_presence(root_uuid, "presence.enter", name, type, uuid)
          {:ok, %{pid: pid, uuid: uuid, name: name, type: type, dir_uuid: root_uuid}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Build a presence_stopper function compatible with Server.shutdown.
  # Broadcasts presence.leave on the dir and stops the Presence.Server
  # (its terminate/2 callback removes the .bot file from the schema).
  defp presence_stopper(root_uuid) do
    fn info ->
      %{pid: pid, uuid: uuid, name: name, type: type} = info

      broadcast_presence(root_uuid, "presence.leave", name, type, uuid)

      if is_pid(pid) and Process.alive?(pid) do
        # Use sync stop so terminate/2 runs (removing the .bot file) before
        # the escript exits. Short timeout — if it hangs, we exit anyway.
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end
  end

  defp broadcast_presence(dir_uuid, event_type, name, type, uuid) do
    Commonplace.Dataflow.Magenta.send(
      dir_uuid,
      Commonplace.Dataflow.Magenta.message(event_type, name, %{
        "name" => name,
        "type" => Atom.to_string(type),
        "uuid" => uuid,
        "dir_uuid" => dir_uuid
      })
    )
  end
end
