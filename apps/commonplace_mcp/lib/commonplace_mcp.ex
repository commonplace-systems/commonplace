defmodule Commonplace.MCP do
  @moduledoc """
  The `commonplace_mcp` escript entry point — the front door an MCP
  client (e.g. Claude Code) knocks on to join a live commonplace workspace.

  ## Why this module exists

  An MCP client needs to read and write commonplace's dataflow channels
  and invoke CLI verbs as tools. Opening the workspace's CubDB store
  directly from the escript is rejected for two reasons:

  - **Two openers corrupt the store.** `commonplace serve` holds the
    workspace's CubDB open. A second opener racing on the same files
    corrupts it. There can be exactly one writer.
  - **Audit events must land on the shared graph.** Every write emits
    events that other agents, the web UI, and sync peers observe via
    PubSub. An isolated escript node would drop those events into a
    private void.

  This escript is a **thin bridge, not a store**: it refuses to serve
  unless `commonplace serve` is already running, attaches to that node
  over distributed Erlang, and routes all store traffic through it via
  `Commonplace.Store.CommitStoreClient`. This is the
  **refuse-without-serve contract**: no serve → hard exit 1 with an
  actionable stderr message. See `attach_to_serve/0` and the
  `{:error, :not_running}` arm of `main/1`.

  ## The blue/red/magenta layer model

  commonplace's dataflow is split into color-coded channels, defined
  canonically in `Commonplace.Dataflow.Channel`. Three matter here:

  - **blue** — the CRDT documents themselves (the durable state an
    agent reads and writes).
  - **red** — persistent, append-only event logs
    (`Commonplace.Dataflow.RedLog`). A red log is a YArray that
    accumulates events forever; it is the durable backbone of an
    agent's *mailbox*.
  - **magenta** — ephemeral, fire-and-forget pub/sub on path-based
    topics (`Commonplace.Dataflow.Magenta`, riding Phoenix.PubSub). A
    magenta message is `{type, source, payload, timestamp}` and reaches
    only processes subscribed *right now* — nothing is retained. Two
    topic shapes matter here: a directory's presence topic (for
    enter/leave broadcasts) and a per-agent address topic `agents/<name>`
    (where senders drop mail).

  The mailbox bridges layers: a **magenta→red onramp** subscribes to
  the agent's magenta address topic and appends every message into the
  agent's red log. Live delivery is ephemeral (magenta); the
  recoverable backlog is durable (red). See "Presence + mailbox
  bootstrap" below.

  ## The stderr routing fix (CX-re6b)

  stdout is the JSON-RPC transport and carries only protocol frames.
  The Erlang `:logger` defaults to stdout, as do warnings from
  `anubis_mcp`, presence-bootstrap diagnostics, and CommitStore events.
  A single interleaved Logger line poisons the stream: the MCP client
  logs it as "Ignoring non-JSON line on stdout," and a long log entry
  can be misread as a protocol response, tearing the transport down.
  `main/1`'s *first* act is therefore `redirect_logger_to_stderr/0`,
  which re-points the `:default` logger handler at `:standard_error`.
  Everything diagnostic in this module uses `IO.puts(:stderr, …)` for
  the same reason.

  ## The serving layer: anubis, not the hand-rolled substrate

  This escript does NOT run the line-by-line loop in
  `Commonplace.MCP.Stdio`. That hand-rolled JSON-RPC layer
  (`Stdio` + `Commonplace.MCP.Server` + `Commonplace.MCP.Protocol`) is
  retained on disk but unwired from stdin — CX-xaof tracks its removal.
  All live traffic is served by `Commonplace.MCP.AnubisServer`, an
  `anubis_mcp`-backed server supervised under a one-for-one tree.
  `main/1` blocks on a monitor of that supervisor; anubis shuts down on
  stdin EOF, the supervisor goes `:DOWN`, and the escript returns.

  Tool/resource registration still flows through `Commonplace.MCP.Tools`
  and `Commonplace.MCP.Resources` — AnubisServer only translates
  anubis's dispatch into the call surface those modules already expose.

  ## Presence + mailbox bootstrap

  Joining a workspace means more than opening a transport: the agent
  must announce itself and start receiving mail. This module supplies
  AnubisServer with two closures (stored in `:persistent_term`) via
  `AnubisServer.config/1`:

  - **`presence_starter/1`** spawns a `Commonplace.Presence.Server`
    (writes a `.bot` presence file and runs a heartbeat) and broadcasts
    `presence.enter` on the directory's magenta topic. It then starts a
    per-agent **mailbox onramp**: a `RedLog` onramp
    (`Commonplace.Dataflow.RedLog.start_onramp/3`) subscribed to the
    agent's magenta address topic, appending every message into a red
    log whose UUID is derived from the agent's cold identity via
    `Commonplace.Presence.Mailbox.log_uuid_for_identity/1`. That
    derivation is what makes offline mail recoverable — traced under
    "Worked example: identity → mailbox UUID → recovery" below.
    Mailbox failure is graceful: presence still starts without a mailbox.
  - **`presence_stopper/1`** flushes and stops the onramp (persisting
    the session's final addressed messages), broadcasts `presence.leave`,
    then *synchronously* stops the Presence.Server so its `terminate/2`
    removes the `.bot` file before the escript exits.

  Anubis calls these after the initialize handshake completes — see
  `Commonplace.MCP.AnubisServer` ("Presence + mailbox bootstrap") for
  why init/terminate (not the initialize response) is the hook point,
  and why clients fetch identifiers via a `presence_info` tool call
  instead of `serverInfo`.

  ### Worked example: identity → mailbox UUID → recovery

  This trace ties together the determinism claim, the red log, and
  why mail survives a disconnect. Say an agent has cold
  `identity_uuid` `"7e3a…"` — a stable per-agent identity that does
  NOT change between sessions (distinct from the per-session presence
  `uuid`, which does).

  1. On connect, `presence_starter/1` spawns a `Presence.Server` and
     reads back its `identity_uuid` (`"7e3a…"`).
  2. `start_mailbox/3` calls
     `Commonplace.Presence.Mailbox.log_uuid_for_identity("7e3a…")`,
     which is a pure `uuid5(:url, "urn:commonplace:agent-mailbox:" <>
     "7e3a…")`. Pure means: *same identity in, same log UUID out, every
     session, forever.* Call it `M`.
  3. The onramp begins tailing magenta topic `agents/<name>` and
     appending each message into red log `M`. Because a red log is
     append-only and persisted to the commit store, `M` already holds
     everything written during prior sessions.
  4. The agent disconnects. A peer sends mail:
     `Magenta.send("agents/<name>", msg)`. With no onramp subscribed,
     the magenta broadcast evaporates — *unless* the peer's own write
     path also appends to `M` (the durable copy survives regardless of
     who is listening). The ephemeral magenta frame is lost; the
     red-log entry is not.
  5. The agent reconnects in a new session. Its `identity_uuid` is
     still `"7e3a…"`, so step 2 re-derives the *same* `M`. The onramp
     loads `M` from the store (`RedLog.load/2`) and the agent sees the
     full backlog — including messages sent while it was offline.

  Because the mailbox UUID is a *pure function of cold identity*, an
  agent never needs to be told where its mailbox lives — it recomputes
  the address from who it is. No per-session provisioning, no registry
  lookup, no lost mail. See `Commonplace.Presence.Mailbox` for the
  derivation and `Commonplace.Dataflow.RedLog` (`load/2`,
  `start_onramp/3`) for the persistence.

  ## Which directory does presence land in? (CX-voi)

  An agent is typically launched from inside a *sandbox checkout*, not
  the workspace root, and presence should land where the agent actually
  is. `resolve_presence_uuid/2` calls
  `Commonplace.Sync.CheckoutRegistry.find_for_cwd/2` (reads
  `checkouts.json` directly — no running registry process required) to
  map cwd to the most tightly enclosing checkout's UUID, falling back
  to the workspace `root_uuid` when cwd is outside every registered
  checkout.

  ## Worked example: a Claude Code session in a sandbox checkout

  Client launches `commonplace_mcp` with cwd
  `~/ws/sandboxes/feature-x` (a registered checkout, uuid `C`);
  workspace root uuid is `R`.

  1. `main/1` redirects Logger → stderr.
  2. `attach_to_serve/0`: `Workspace.discover/1` walks up to find
     `.commonplace/`, reads `node_name` → the serve node atom, starts a
     short-lived randomly-named node, sets
     `:prevent_overlapping_partitions = false` (CX-y6uc — without this,
     `:global` mistakes each ephemeral escript for a network partition
     and forcibly disconnects later ones, surfacing as MCP "Connection
     closed"), connects, points CommitStoreClient at the serve node,
     reads `root` → `R`. Returns `{:ok, R, data_dir}`.
  3. `resolve_presence_uuid(data_dir, R)`: cwd is inside checkout `C`,
     so presence_uuid = `C`, not `R`.
  4. `AnubisServer.config/1` stashes the two closures (rooted at `C`).
  5. Supervisor starts AnubisServer on `:stdio`; `main/1` blocks on the
     monitor.
  6. Client completes initialize; anubis calls the starter: a
     Presence.Server appears under dir `C` (heartbeat begins, `.bot`
     file written), `presence.enter` broadcasts on `C`'s magenta topic,
     and a mailbox onramp begins tailing topic `agents/<name>` into red
     log `uuid5(identity)` — picking up anything sent since last session.
  7. Client calls `tools/call presence_info`, learns its presence_uuid
     and mailbox coordinates.
  8. Client closes stdin → anubis shuts down → terminate fires the
     stopper: onramp commits its tail, `presence.leave` broadcasts on
     `C`, Presence.Server stops synchronously (removing the `.bot`
     file), supervisor goes `:DOWN`, `main/1`'s `receive` returns.

  Contrast: launch from the workspace root (`~/ws`). Step 3 finds no
  enclosing checkout, so presence_uuid falls back to `R` and the agent
  appears at the root.

  ## Sister modules (chase the thread)

  - `Commonplace.MCP.AnubisServer` — the actual MCP server; consumes
    the two closures this module configures.
  - `Commonplace.Workspace` — `discover/1` (find `.commonplace/`) and
    `root_uuid/0`.
  - `Commonplace.Store.CommitStoreClient` — `set_remote_node/1` aims all
    store calls at the attached serve node.
  - `Commonplace.Presence.Server` / `Commonplace.Presence.Mailbox` —
    presence document + heartbeat, and the deterministic mailbox-log
    derivation.
  - `Commonplace.Dataflow.RedLog` — `start_onramp/3` / `commit_onramp/1`
    drive the mailbox.
  - `Commonplace.Dataflow.Magenta` — the ephemeral pub/sub channel
    presence and mailboxes ride on.
  - `Commonplace.Dataflow.Channel` — canonical definition of the
    blue/red/magenta (and cyan/green) color layers.
  - `Commonplace.Sync.CheckoutRegistry` — `find_for_cwd/2` resolves the
    presence directory.
  """

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.MCP.AnubisServer
  alias Commonplace.Presence.Mailbox
  alias Commonplace.Presence.Server, as: PresenceServer
  alias Commonplace.Sync.CheckoutRegistry

  @doc """
  escript entry point; the session's entire lifecycle in one function.

  Executes a sequence of gates before serving: redirect Logger to
  stderr, then `attach_to_serve/0`. Each failure arm is a deliberate
  **refusal** — an actionable stderr message and `System.halt(1)` rather
  than a half-working session (the refuse-without-serve contract). On
  success: resolve the presence directory, hand AnubisServer its
  presence closures, start the anubis session on `:stdio`, then *block*
  on a monitor of the supervisor. That `receive` is what keeps the
  escript — and the agent's presence/mailbox — alive until the client
  closes stdin.
  """
  def main(_argv \\ []) do
    # CX-re6b: redirect Logger to stderr before anything touches stdout.
    # See @moduledoc "The stderr routing fix" for rationale.
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
        # CX-voi: presence lands in the enclosing sandbox checkout, not
        # always the workspace root. Falls back to root_uuid when cwd
        # is outside every registered checkout.
        presence_uuid = resolve_presence_uuid(data_dir, root_uuid)

        # CX-hf71: stash presence hooks in :persistent_term for
        # AnubisServer to call in init/2 + terminate/2. All live MCP
        # traffic goes through anubis; the hand-rolled Server path is
        # retained on disk for CX-xaof to remove.
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

  # Reconfigure the Erlang :logger default handler to write to
  # `:standard_error` instead of stdout. stdout is the JSON-RPC
  # transport; any Logger line interleaved there corrupts the protocol.
  #
  # Belt-and-suspenders: try update_handler_config first; on failure
  # (handler missing or rejected the partial update), remove and
  # re-add the handler pointed at stderr.
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

  # CX-voi: map cwd → nearest enclosing checkout UUID, falling back to
  # root_uuid. See @moduledoc "Which directory does presence land in?"
  defp resolve_presence_uuid(data_dir, root_uuid) do
    config_path = Path.join(data_dir, "checkouts.json")

    # find_for_cwd/2 returns {:ok, %{uuid: ..., sync_dir: ..., type: ...}}
    # for the most tightly enclosing checkout, or :none when cwd is
    # outside every checkout (or checkouts.json is missing). The two
    # arms below are therefore total — no other shape is possible. See
    # `Commonplace.Sync.CheckoutRegistry.find_for_cwd/2`.
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

  # Build the presence_starter closure for AnubisServer.
  # Spawns a Presence.Server rooted at `root_uuid`, broadcasts
  # `presence.enter` on the dir's magenta topic, then starts a
  # per-agent mailbox onramp (CX-92u). The onramp subscribes to
  # `agents/{name}` on magenta and appends each message to a red log
  # whose UUID is derived deterministically from the agent's cold
  # identity — so on reconnect the agent tails the same log and
  # recovers messages sent while offline. Mailbox failure is graceful:
  # presence still starts without a mailbox.
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

  # Start the agent's mailbox; return fields to merge into the presence
  # info map. On success: `%{mailbox_uuid: uuid, mailbox_topic: topic,
  # mailbox_pid: pid}`. On failure: `%{}` (see the failure arm below
  # for why that's safe). The caller (presence_starter/1) Map.merges
  # this into the base presence map either way.
  #
  # mailbox_uuid is the deterministic red-log address derived from the
  # agent's cold identity (see @moduledoc "identity → mailbox UUID →
  # recovery"); mailbox_topic is the magenta address `agents/<name>`.
  defp start_mailbox(name, identity_uuid, store) do
    mailbox_uuid = Mailbox.log_uuid_for_identity(identity_uuid)
    mailbox_topic = Mailbox.topic_for_name(name)

    # Subscribe a magenta→red onramp to `agents/<name>` and persist
    # every message into red log `mailbox_uuid`. Failure is graceful:
    # a crashed onramp must not abort the agent's join — presence is
    # required, mail delivery is not (see the {:error} arm).
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

        # Empty map is safe: presence_starter/1 Map.merges this into
        # the base presence map, so the agent still gets a complete
        # presence record (pid/uuid/name/type/dir_uuid) with no
        # mailbox_* keys. presence_stopper/1's stop_mailbox/1 falls
        # through its catch-all when no mailbox_pid is present — teardown
        # is a no-op. The agent joins and runs fully, without durable
        # mail this session.
        %{}
    end
  end

  # Build the presence_stopper closure for AnubisServer.
  # Flushes and stops the mailbox onramp (CX-92u — persists the
  # session's final addressed messages), broadcasts `presence.leave`,
  # then synchronously stops the Presence.Server so its `terminate/2`
  # removes the `.bot` file before the escript exits.
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
