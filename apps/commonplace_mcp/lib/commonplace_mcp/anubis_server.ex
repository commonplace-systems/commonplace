defmodule Commonplace.MCP.AnubisServer do
  @moduledoc """
  MCP server backed by `anubis_mcp` (CX-hf71).

  Replaces the hand-rolled `Commonplace.MCP.{Server, Stdio, Protocol}`
  layers from the pre-CX-hf71 code. Tool and resource registration stays
  routed through the existing `Commonplace.MCP.Tools` / `Resources`
  modules — this server translates anubis's `handle_request/2` dispatch
  into the same call surface those modules already expose.

  ## Presence + mailbox bootstrap (CX-92u, CX-voi)

  Anubis calls `init/2` AFTER the initialize handshake completes
  (post `notifications/initialized`). That's where we spawn the
  `Commonplace.Presence.Server` and the per-agent mailbox onramp, then
  stash the presence identifiers — presence_uuid, mailbox_uuid,
  mailbox_topic, plus `presence_path` (the agent's bound name like
  `"commonplace.bot"`, CX-9rbc, used so `ViewActionDispatch` can fill
  author_path without a substrate reverse-lookup) — into
  `frame.assigns`, where the `presence_info` tool and every
  `tools/call` context (`presence_context/1`) read them back.

  Presence is best-effort: if `config/1` never ran (no
  `presence_starter` in `:persistent_term`) or the starter errors,
  `init/2` logs a warning and proceeds with empty assigns —
  `presence_info` then returns all-nil fields but the session still
  works.

  ### Wire contract break

  The pre-CX-hf71 server put `presenceUuid` / `mailboxUuid` /
  `mailboxTopic` in the `initialize` response's `serverInfo`. Anubis's
  hard-coded initialize handler doesn't let us enrich that payload.
  Clients now call `tools/call presence_info` (snake_case keys) after
  initialization instead. CX-xaof removes the hand-rolled substrate
  once this path has proven itself.

  ## Crash resilience (CX-0nkq, CX-re6b)

  Every `handle_request/2` branch runs its real work inside
  `safe_invoke/1`, which catches `:exit` / `:error` / `:throw` and
  returns them as a tagged tuple. The disease: a handler can raise an
  exit — most often a `CommitStore` `GenServer.call` timeout under
  load (CX-0nkq) — and an uncaught exit propagates up through anubis's
  per-session GenServer, tearing the whole stdio transport down and
  killing the agent's session.

  Instead, a caught crash becomes a *survivable* failure: `tools/call`
  returns an **in-band** MCP error (`%{"isError" => true, …}`) so the
  agent sees a retryable tool failure, and the read-only handlers
  (`tools/list`, `resources/*`) return a protocol execution error.
  Either way the session lives. (Originally only `tools/call` was
  guarded; CX-re6b extended the same wrap to every handler once a rare
  `tools/list` timeout — it reads the CRDT-tools schema — became the
  surviving session-killer after CX-71ej dropped CommitStore queue
  load.) A `[:commonplace, :mcp, :tool_call, :crashed]` telemetry
  event fires on each intercepted `tools/call` crash.

  ## Shutdown

  `terminate/2` invokes the configured `presence_stopper` (same
  signature as the hand-rolled server) so mailbox onramps commit
  their tail events and `.bot` presence files are removed before the
  escript exits.
  """

  use Anubis.Server,
    name: "commonplace-mcp",
    version: "0.2.0",
    capabilities: [:tools, :resources]

  alias Anubis.MCP.Error
  alias Anubis.Server.Frame
  alias Commonplace.MCP.{Resources, Tools}

  @doc """
  Build a configuration for starting the server under a supervisor.

  Accepts:
    * `:presence_starter` — `(String.t(), atom() -> {:ok, map} | {:error, term})`
    * `:presence_stopper` — `(map -> any)`

  These are stored in a per-session agent keyed by pid so `init/2` and
  `terminate/2` can reach them. Pattern mirrors the hand-rolled
  `Commonplace.MCP.Server.new/1` injection surface so the escript's
  existing presence-bootstrap closures drop in unchanged.
  """
  def config(opts \\ []) do
    starter = Keyword.get(opts, :presence_starter)
    stopper = Keyword.get(opts, :presence_stopper)

    # Store hooks in :persistent_term under a per-process key so each
    # init/terminate callback can find them. A keyed Agent would work
    # too, but persistent_term keeps the module stateless and matches
    # how CommitStoreClient.set_remote_node distributes per-node state.
    :persistent_term.put({__MODULE__, :presence_starter}, starter)
    :persistent_term.put({__MODULE__, :presence_stopper}, stopper)
    :ok
  end

  @impl Anubis.Server
  def init(client_info, frame) do
    client_name = Map.get(client_info, "name") || "mcp-agent"

    starter = :persistent_term.get({__MODULE__, :presence_starter}, nil)

    frame =
      case starter && starter.(client_name, :bot) do
        {:ok, %{} = info} ->
          frame
          |> Frame.assign(:presence_info, info)
          |> Frame.assign(:presence_uuid, Map.get(info, :uuid))
          |> Frame.assign(:mailbox_uuid, Map.get(info, :mailbox_uuid))
          |> Frame.assign(:mailbox_topic, Map.get(info, :mailbox_topic))
          # CX-9rbc (sub-bead iii of CX-8cw5): expose the agent's bound
          # name (e.g. "commonplace.bot") so ViewActionDispatch's auto-
          # resolution can fill author_path without a substrate
          # reverse-lookup. Substrate-wide value — any future action
          # needing author identity reads it from frame.assigns.
          |> Frame.assign(:presence_path, Map.get(info, :name))
          # CX-88mw(iii): per-session signing bootstrap — mint
          # (idempotently) the agent's keypair and stash a ready
          # SigningContext so every Tools.call context carries it and
          # action commits are signed by the SESSION's bound key
          # instead of the "mcp-agent@local" placeholder.
          |> assign_signing_context(Map.get(info, :identity_uuid))

        nil ->
          # CX-m8xl: presence_starter NOT in :persistent_term — escript
          # main/0 didn't run AnubisServer.config before the supervisor
          # started, OR the persistent_term key was cleared. Either way,
          # the agent's presence_info tool will return all-NIL fields.
          require Logger

          Logger.warning(
            "AnubisServer.init/2 (#{inspect(client_name)}): no presence_starter " <>
              "in :persistent_term. presence_info will return nil values. " <>
              "Check that Commonplace.MCP.AnubisServer.config/1 was called " <>
              "before Supervisor.start_link in the escript main/0."
          )

          frame

        false ->
          # `starter && starter.(...)` short-circuited because starter
          # was non-nil but falsy (impossible in practice — starter
          # values are functions). Defensive branch.
          require Logger
          Logger.warning("AnubisServer.init/2 (#{inspect(client_name)}): starter short-circuited unexpectedly")
          frame

        other ->
          # CX-m8xl: presence_starter exists but returned non-:ok. Most
          # likely PresenceServer.start_link failed (e.g. CommitStore
          # call timed out under load — CX-0nkq territory). Surface so
          # operators can correlate with downstream presence_info NIL.
          require Logger

          Logger.warning(
            "AnubisServer.init/2 (#{inspect(client_name)}): presence_starter " <>
              "returned #{inspect(other)}. presence_info will return nil values."
          )

          frame
      end

    {:ok, frame}
  end

  # CX-88mw(iii): mint (idempotent) + load the per-agent signing key for
  # the session's COLD identity uuid (the persistent actor record — hot
  # presence uuids change per session). Best-effort, mirroring the
  # presence bootstrap: any failure (SecretStore down, corrupt slots,
  # legacy starter without :identity_uuid) logs and leaves the session
  # unsigned rather than killing the handshake.
  defp assign_signing_context(frame, identity_uuid) when is_binary(identity_uuid) do
    alias Commonplace.Crypto.AgentKeys

    case safe_invoke(fn ->
           with {:ok, _pub} <- AgentKeys.ensure(identity_uuid),
                {:ok, ctx} <- AgentKeys.signing_context_for(identity_uuid) do
             {:ok, ctx}
           end
         end) do
      {:ok, {:ok, ctx}} ->
        Frame.assign(frame, :signing_context, ctx)

      other ->
        require Logger

        Logger.warning(
          "AnubisServer: per-agent signing bootstrap failed for identity " <>
            "#{identity_uuid}: #{inspect(other, limit: 50)}. Session commits " <>
            "will fall back to the unsigned/placeholder path."
        )

        frame
    end
  end

  defp assign_signing_context(frame, _no_identity_uuid), do: frame

  @impl Anubis.Server
  def terminate(_reason, frame) do
    stopper = :persistent_term.get({__MODULE__, :presence_stopper}, nil)

    case {stopper, frame.assigns[:presence_info]} do
      {stopper, %{} = info} when is_function(stopper, 1) -> stopper.(info)
      _ -> :ok
    end
  end

  @impl Anubis.Server
  def handle_request(%{"method" => "tools/list"}, frame) do
    case safe_invoke(fn -> Tools.list() end) do
      {:ok, tools} ->
        {:reply, %{"tools" => tools}, frame}

      {:error, crash} ->
        log_handler_crash("tools/list", crash)
        {:error, Error.execution(crash_text("tools/list", crash)), frame}
    end
  end

  def handle_request(%{"method" => "tools/call", "params" => params}, frame) do
    name = Map.get(params || %{}, "name")
    args = Map.get(params || %{}, "arguments", %{})
    context = presence_context(frame)

    case safe_invoke(fn -> Tools.call(name, args, context) end) do
      {:ok, {:ok, result}} ->
        {:reply, result, frame}

      {:ok, {:error, :not_found}} ->
        {:error, Error.protocol(:method_not_found, %{method: name}), frame}

      {:ok, {:error, :invalid_params, detail}} ->
        {:error, Error.protocol(:invalid_params, %{message: detail}), frame}

      {:ok, {:error, reason}} ->
        {:error, Error.execution(stringify(reason)), frame}

      {:error, crash} ->
        if clean_disconnect?(crash) do
          # CX-gq7a: `GenServer.call` against a session that already
          # exited normally (e.g. a bot's PlayerSession stopping after
          # `quit`, drained a beat later) surfaces as `:noproc` — plain
          # teardown, not a crash. Reporting this as an error with the
          # CX-0nkq overload hint mis-blamed CommitStore for what is
          # ordinary session-end housekeeping.
          {:reply,
           %{
             "isError" => false,
             "content" => [
               %{"type" => "text", "text" => "tool '#{name}': session ended (clean disconnect)."}
             ]
           }, frame}
        else
          # In-band MCP tool error so the agent sees the failure and the
          # session stays alive. Without this, an exit raised inside the
          # tool (e.g. CommitStore GenServer.call timeout under load —
          # CX-0nkq) propagates up through anubis's session GenServer
          # and tears the stdio transport down.
          {kind, reason} =
            case crash do
              {kind, reason, _stack} -> {kind, reason}
              {kind, reason} -> {kind, reason}
            end

          :telemetry.execute(
            [:commonplace, :mcp, :tool_call, :crashed],
            %{system_time: System.system_time()},
            %{tool: name, kind: kind, reason: reason}
          )

          log_handler_crash("tools/call(#{name})", crash)

          hint =
            # CX-gq7a: the CX-0nkq overload hint is only warranted for an
            # actual `GenServer.call` timeout — not for raised exceptions
            # (`:error`), thrown values (`:throw`), or other exit reasons.
            # Previously this was appended unconditionally to ANY
            # tools/call failure.
            if timeout_crash?(crash) do
              " Likely a CommitStore overload (CX-0nkq). Retrying may help."
            else
              ""
            end

          text = "tool '#{name}' crashed: #{kind} #{format_crash_reason(crash)}.#{hint}"

          {:reply,
           %{
             "isError" => true,
             "content" => [%{"type" => "text", "text" => text}]
           }, frame}
        end
    end
  end

  def handle_request(%{"method" => "resources/list"}, frame) do
    case safe_invoke(fn ->
           %{
             "resources" => Resources.list(),
             "resourceTemplates" => Resources.templates()
           }
         end) do
      {:ok, result} ->
        {:reply, result, frame}

      {:error, crash} ->
        log_handler_crash("resources/list", crash)
        {:error, Error.execution(crash_text("resources/list", crash)), frame}
    end
  end

  def handle_request(%{"method" => "resources/read", "params" => params}, frame) do
    uri = Map.get(params || %{}, "uri", "")

    case safe_invoke(fn -> Resources.read(uri) end) do
      {:ok, {:ok, contents}} ->
        {:reply, %{"contents" => contents}, frame}

      {:ok, {:error, :not_found}} ->
        {:error, Error.resource(:not_found, %{uri: uri}), frame}

      {:ok, {:error, reason}} ->
        {:error, Error.execution(stringify(reason)), frame}

      {:error, crash} ->
        log_handler_crash("resources/read(#{uri})", crash)
        {:error, Error.execution(crash_text("resources/read", crash)), frame}
    end
  end

  def handle_request(%{"method" => method}, frame) do
    {:error, Error.protocol(:method_not_found, %{method: method}), frame}
  end

  @doc """
  Catch :exit, :error, and :throw from any zero-arg function and convert
  them to a tagged tuple so handle_request branches can return in-band
  MCP errors instead of letting the exit propagate up to anubis's
  session GenServer (which would tear down the stdio transport).

  Returns:
    * `{:ok, value}` on success
    * `{:error, {:exit, reason}}` for GenServer.call timeouts, dead pids, etc.
    * `{:error, {:error, exception, stacktrace}}` for raised exceptions
    * `{:error, {:throw, value}}` for thrown values

  CX-re6b: previously only `tools/call` had this protection (CX-0nkq).
  When the CX-71ej fix dropped CommitStore queue load, the surviving
  rare-timeout in `tools/list` (which reads the CRDT-tools schema)
  became the new session-killer. Symmetric protection on every
  handler removes the whole class of failure.
  """
  def safe_invoke(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      :throw, reason -> {:error, {:throw, reason}}
      kind, reason when kind in [:error] -> {:error, {kind, reason, __STACKTRACE__}}
    end
  end

  defp log_handler_crash(label, crash) do
    require Logger
    Logger.warning("MCP handler crash in #{label}: #{inspect(crash, limit: 200)}")
  end

  defp crash_text(label, crash) do
    "#{label} crashed: #{format_crash_reason(crash)}. " <>
      "Session preserved via safe_invoke (CX-re6b). Retrying may help."
  end

  defp format_crash_reason({:exit, reason}), do: Exception.format_exit(reason)
  defp format_crash_reason({:throw, value}), do: "throw " <> inspect(value)
  defp format_crash_reason({:error, exception, _stack}), do: Exception.message(exception)
  defp format_crash_reason(other), do: inspect(other)

  @doc """
  CX-gq7a: true if `crash` (a `safe_invoke/1` error tuple) represents a
  process that already exited cleanly rather than an actual failure —
  e.g. a `GenServer.call` against a session process that has already
  exited (a bot's `PlayerSession` stopping after `quit`, then
  `Bot.send_input`'s drain call landing a beat later) raises `:noproc`.
  That's normal teardown, not a tool crash, and must not be reported
  as one. `:normal` (an exit forwarded straight through, not wrapped
  in a `GenServer.call` failure tuple) is the same story.

  Public so the distinction is directly testable — mirrors
  `safe_invoke/1`'s own precedent (CX-re6b).
  """
  def clean_disconnect?({:exit, :noproc}), do: true
  def clean_disconnect?({:exit, {:noproc, _}}), do: true
  def clean_disconnect?({:exit, :normal}), do: true
  def clean_disconnect?({:exit, {:normal, _}}), do: true
  def clean_disconnect?(_), do: false

  @doc """
  CX-gq7a: true only for a genuine `GenServer.call` timeout — the only
  case that warrants the CX-0nkq CommitStore-overload hint. Previously
  the hint was appended unconditionally to any `tools/call` crash.
  """
  def timeout_crash?({:exit, :timeout}), do: true
  def timeout_crash?({:exit, {:timeout, _}}), do: true
  def timeout_crash?(_), do: false

  defp presence_context(frame) do
    %{
      presence_uuid: frame.assigns[:presence_uuid],
      mailbox_uuid: frame.assigns[:mailbox_uuid],
      mailbox_topic: frame.assigns[:mailbox_topic],
      # CX-9rbc: thread the agent's bound name down to Tools.call so
      # ViewActionDispatch's auto-resolution (CX-icc2) can fill
      # author_path without a reverse-lookup.
      presence_path: frame.assigns[:presence_path],
      # CX-88mw(iii): the session's real SigningContext (or nil for
      # legacy/keyless sessions). InvokeViewAction threads it into
      # ViewActionDispatch so action commits are signed by the agent.
      signing_context: frame.assigns[:signing_context]
    }
  end

  defp stringify(reason) when is_binary(reason), do: reason
  defp stringify(reason), do: inspect(reason)
end
