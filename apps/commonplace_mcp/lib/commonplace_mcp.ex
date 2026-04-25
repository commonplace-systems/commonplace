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

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.MCP.AnubisServer
  alias Commonplace.Presence.Mailbox
  alias Commonplace.Presence.Server, as: PresenceServer
  alias Commonplace.Sync.CheckoutRegistry

  def main(_argv \\ []) do
    # CX-re6b: route Elixir Logger output to stderr. The MCP escript
    # uses stdout as its JSON-RPC transport channel; any Logger write
    # (including the warnings emitted from anubis itself, presence
    # bootstrap diagnostics, and CommitStore events) interleaved on
    # stdout corrupts the protocol stream — Claude Code's MCP client
    # logs them as "Ignoring non-JSON line on stdout" and eventually
    # one parses far enough to be misinterpreted as a response,
    # tearing the transport down.
    redirect_logger_to_stderr()

    # Diagnostic: write to stderr what the default handler config is
    # NOW (after our redirect). If MCP-client logs still show stdout
    # poisoning, this stderr line tells us whether the redirect ran
    # and what the handler ended up looking like.
    case :logger.get_handler_config(:default) do
      {:ok, cfg} ->
        IO.puts(:stderr, "commonplace_mcp: logger default handler config = #{inspect(cfg.config, limit: 5)}")
      other ->
        IO.puts(:stderr, "commonplace_mcp: get_handler_config(:default) = #{inspect(other)}")
    end

    case attach_to_serve() do
      {:ok, root_uuid, data_dir} ->
        # CX-voi: presence lands in the sandbox checkout the agent was
        # launched from, not always at workspace root. Resolve cwd →
        # nearest CheckoutRegistry entry. Fallback to root_uuid when
        # cwd is outside every registered checkout (e.g. agent launched
        # from the workspace root itself).
        presence_uuid = resolve_presence_uuid(data_dir, root_uuid)

        # CX-hf71: register the presence hooks with AnubisServer via
        # :persistent_term (it reads them back in init/2 + terminate/2).
        # The hand-rolled Commonplace.MCP.Server path is retained on
        # disk for CX-xaof to clean up; it is no longer wired to
        # stdio. All live MCP traffic goes through anubis.
        :ok =
          AnubisServer.config(
            presence_starter: presence_starter(presence_uuid),
            presence_stopper: presence_stopper(presence_uuid)
          )

        {:ok, sup} =
          Supervisor.start_link(
            [{AnubisServer, transport: :stdio}],
            strategy: :one_for_one
          )

        # Block the escript so the supervisor keeps the anubis
        # session + stdio transport alive. Anubis terminates cleanly
        # on stdin EOF via its own shutdown path.
        Process.monitor(sup)

        receive do
          {:DOWN, _ref, :process, ^sup, _} -> :ok
        end

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

  # Reconfigure the Erlang :logger default handler so Elixir's Logger
  # writes to stderr (`:standard_error`) instead of stdout. The MCP
  # escript uses stdout as its JSON-RPC transport — any Logger output
  # interleaved on stdout is interpreted by the MCP client as garbled
  # protocol traffic and eventually drops the transport.
  #
  # Belt-and-suspenders: try update_handler_config first, then if that
  # returned an error tuple OR the handler had been swapped to a fresh
  # one with stdout config, remove the default and re-add it pointed at
  # stderr. We also retry after Application.ensure_all_started for
  # :anubis_mcp / :hermes_mcp in case those install their own handlers.
  defp redirect_logger_to_stderr do
    update_result =
      try do
        :logger.update_handler_config(:default, :config, %{type: :standard_error})
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case update_result do
      :ok ->
        :ok

      {:error, _reason} ->
        # Handler missing or rejected the partial update — replace it.
        try do
          :logger.remove_handler(:default)
        catch
          _, _ -> :ok
        end

        try do
          :logger.add_handler(:default, :logger_std_h, %{
            config: %{type: :standard_error},
            formatter:
              {:logger_formatter,
               %{single_line: true, template: [:level, " ", :msg, "\n"]}}
          })
        catch
          _, _ -> :ok
        end
    end

    :ok
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
              {:ok, root_uuid, data_dir}
            end
        end
    end
  end

  # CX-voi: pick the presence dir_uuid — nearest enclosing checkout
  # for the escript's cwd, falling back to workspace root_uuid when
  # cwd is outside every registered checkout.
  defp resolve_presence_uuid(data_dir, root_uuid) do
    config_path = Path.join(data_dir, "checkouts.json")

    case CheckoutRegistry.find_for_cwd(config_path, File.cwd!()) do
      {:ok, %{uuid: uuid}} -> uuid
      :none -> root_uuid
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
    # CX-y6uc: disable :global's overlapping-partition protection
    # (default-on since OTP 25). Each MCP escript invocation is a
    # short-lived node joining + leaving; the heuristic mistakes that
    # for a partition and forcibly disconnects subsequent escripts,
    # surfacing as MCP "Connection closed" errors. Must be set before
    # Node.start.
    :application.set_env(:kernel, :prevent_overlapping_partitions, false)

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
  #
  # CX-92u: also spawns a per-agent mailbox onramp. The onramp subscribes
  # to `agents/{name}` on magenta and appends each message to a red log
  # whose UUID is derived deterministically from the agent's cold
  # identity — so when the agent reconnects, it tails the same log and
  # picks up any messages sent while it was offline. Mailbox failures
  # degrade gracefully: presence still starts without a mailbox.
  defp presence_starter(root_uuid) do
    fn name, type ->
      store = Commonplace.Store.CommitStoreClient

      case PresenceServer.start_link(
             name: name,
             type: type,
             dir_uuid: root_uuid,
             store: store
           ) do
        {:ok, pid} ->
          uuid = PresenceServer.uuid(pid)
          identity_uuid = PresenceServer.identity_uuid(pid)
          broadcast_presence(root_uuid, "presence.enter", name, type, uuid)

          base = %{pid: pid, uuid: uuid, name: name, type: type, dir_uuid: root_uuid}
          {:ok, Map.merge(base, start_mailbox(name, identity_uuid, store))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp start_mailbox(name, identity_uuid, store) do
    mailbox_uuid = Mailbox.log_uuid_for_identity(identity_uuid)
    mailbox_topic = Mailbox.topic_for_name(name)

    case RedLog.start_onramp(mailbox_uuid, mailbox_topic, store) do
      {:ok, onramp_pid} ->
        %{
          mailbox_uuid: mailbox_uuid,
          mailbox_topic: mailbox_topic,
          mailbox_pid: onramp_pid
        }

      {:error, reason} ->
        require Logger

        Logger.warning(
          "commonplace_mcp: failed to start mailbox onramp for #{name}: " <> inspect(reason)
        )

        %{}
    end
  end

  # Build a presence_stopper function compatible with Server.shutdown.
  # Broadcasts presence.leave on the dir and stops the Presence.Server
  # (its terminate/2 callback removes the .bot file from the schema).
  # CX-92u: also flushes + stops the per-agent mailbox onramp so the
  # final events addressed during this session persist before exit.
  defp presence_stopper(root_uuid) do
    fn info ->
      %{pid: pid, uuid: uuid, name: name, type: type} = info

      stop_mailbox(info)

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

  defp stop_mailbox(%{mailbox_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        RedLog.commit_onramp(pid)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp stop_mailbox(_), do: :ok

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
