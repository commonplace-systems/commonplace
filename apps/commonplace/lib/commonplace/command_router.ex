defmodule Commonplace.CommandRouter do
  @moduledoc """
  Singleton GenServer that routes mutating command verbs through a single
  surface, emitting magenta command.initiated / command.completed / command.failed
  events around each handler call.

  Every command verb (fork, merge, gc, branch_activate, …) is a handle_call
  clause here. The CLI and the MCP server both call through this router instead
  of calling the underlying modules (Fork / Merge / GC / …) directly, so that
  every invocation lands on the `__commands` magenta topic and — via the
  standard magenta→red onramp — on a gold-attested audit chain.

  ## Why this exists

  Commonplace's color-channel design wants a single observable command surface.
  Direct module calls from the CLI bypass magenta entirely, leaving MCP with
  no way to "participate in the graph" beyond blind writes. Full magenta
  pub/sub routing would rebuild GenServer.call from scratch — so we use
  GenServer.call natively here and emit magenta events as a side-effect.
  """

  use GenServer
  require Logger

  alias Commonplace.CommandRouter.Events
  alias Commonplace.Document.{ContentType, Diff}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.GC
  alias Commonplace.Tree.{DocBuilder, Fork, Merge, Schema}

  # CX-kqz3: in_flight_forks dedups concurrent fork requests on the same
  # source_uuid. Without it, an MCP escript whose first fork call timed out
  # at 5s (default GenServer.call timeout) would retry, queuing duplicate
  # fork work behind the first; under repeat retry, all schedulers pinned
  # on serial fork work and net_kernel's heartbeat starved → escript saw
  # serve as :nodedown even though serve was alive.
  defstruct store: nil, in_flight_forks: MapSet.new()

  # The fork timeout has to span the actual fork work. CommandRouter.fork
  # delegates to a Task, but the GenServer.call here STILL waits the same
  # bounded time because it's the outer client's deadline. Default 5s
  # was tight under MCP load; 30s gives a deep tree fork enough runway
  # without inviting the retry storm CX-kqz3 chases.
  @fork_call_timeout 30_000

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fork a directory subtree by DAG-branching from `source_uuid`.
  Returns {:ok, new_uuid} or {:error, reason}.
  Returns `{:error, :fork_in_progress}` if a fork of this source is
  already running (CX-kqz3).
  """
  def fork(server \\ __MODULE__, source_uuid) do
    GenServer.call(server, {:fork, source_uuid}, @fork_call_timeout)
  end

  @doc """
  Three-way CRDT merge from `source_uuid` into `target_uuid`.
  Returns {:ok, summary_map} or {:error, reason}. The summary map has
  keys "merged_count", "new_count", "deleted_count", "conflict_count",
  "auto_renamed" (list of maps), and "conflicts" (list).
  """
  def merge(server \\ __MODULE__, source_uuid, target_uuid) do
    GenServer.call(server, {:merge, source_uuid, target_uuid})
  end

  @doc """
  Run reachability GC starting from `root_uuid`.
  Returns {:ok, report_map} with keys "reachable_count", "orphaned_count",
  and "orphaned_uuids" (list of strings).
  """
  def gc(server \\ __MODULE__, root_uuid) do
    GenServer.call(server, {:gc, root_uuid})
  end

  @doc """
  Activate a named child directory on `parent_uuid` (sets sync=true so the
  sync agent exports it to disk). Returns {:ok, %{...}} or {:error, :not_found}.
  """
  def branch_activate(server \\ __MODULE__, parent_uuid, name) do
    GenServer.call(server, {:branch_set_sync, parent_uuid, name, true})
  end

  @doc """
  Deactivate a named child directory on `parent_uuid` (sets sync=false).
  Returns {:ok, %{...}} or {:error, :not_found}.
  """
  def branch_deactivate(server \\ __MODULE__, parent_uuid, name) do
    GenServer.call(server, {:branch_set_sync, parent_uuid, name, false})
  end

  @doc """
  Update the text content of an existing blue doc identified by `uuid` to
  `new_content`, using a Myers-diff smart merge (character-level insert/delete
  ops) so concurrent CRDT edits are preserved. Returns {:ok, %{...}}; or
  `{:error, :not_found}` if the doc does not exist; or
  `{:error, {:type_mismatch, actual_type}}` (CX-yfva) if the doc's content
  type isn't `:text` and `force: false` (the default).

  Pass `force: true` in `opts` to override the type check and clobber a
  non-text doc into text. The Myers-diff still runs against the
  `ContentType.get_content/1` projection, which for non-text docs may
  produce surprising ops — `force: true` is opt-in destruction.
  """
  # CX-yfva: explicit head + clauses to avoid Elixir's ambiguity with
  # two non-adjacent defaults. The previous shape
  # `def write(server \\ __MODULE__, uuid, new_content, opts \\ [])`
  # caused arity-3 calls (`write(uuid, content, opts)`) to bind
  # `server = uuid`, sending the GenServer.call to a binary instead
  # of a registered name — which then crashed inside MCP's tool
  # dispatch as a FunctionClauseError.
  def write(uuid, new_content) when is_binary(new_content) do
    write(__MODULE__, uuid, new_content, [])
  end

  def write(uuid, new_content, opts) when is_binary(new_content) and is_list(opts) do
    write(__MODULE__, uuid, new_content, opts)
  end

  def write(server, uuid, new_content) when is_binary(new_content) do
    write(server, uuid, new_content, [])
  end

  def write(server, uuid, new_content, opts)
      when is_binary(new_content) and is_list(opts) do
    GenServer.call(server, {:write, uuid, new_content, opts})
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    {:ok, %__MODULE__{store: store}}
  end

  @impl true
  def handle_call({:fork, source_uuid}, from, state) do
    cond do
      MapSet.member?(state.in_flight_forks, source_uuid) ->
        # CX-kqz3: dedup the retry storm. Caller will receive an in-band
        # MCP error and either back off or surface to the user. Crucially
        # the retry does NOT join CommitStore's queue.
        {:reply, {:error, :fork_in_progress}, state}

      true ->
        store = state.store
        router = self()

        # Run the actual fork on a dedicated Task so CommandRouter can
        # process other commands (and reject duplicate fork requests on
        # the same source) while this fork runs. Reply lands later via
        # the {:fork_done, ...} info message.
        Task.start(fn ->
          result =
            Events.run("fork", %{"source_uuid" => source_uuid}, fn ->
              new_uuid = Fork.fork_directory(source_uuid, store)
              {:ok, new_uuid, %{"new_uuid" => new_uuid}}
            end)

          send(router, {:fork_done, from, source_uuid, result})
        end)

        {:noreply, %{state | in_flight_forks: MapSet.put(state.in_flight_forks, source_uuid)}}
    end
  end

  @impl true
  def handle_call({:merge, source_uuid, target_uuid}, _from, state) do
    args = %{"source_uuid" => source_uuid, "target_uuid" => target_uuid}

    result =
      Events.run("merge", args, fn ->
        case Merge.merge(source_uuid, target_uuid, state.store) do
          {:ok, report} ->
            summary = merge_report_summary(report)
            {:ok, summary}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:write, uuid, new_content, opts}, _from, state) do
    force? = Keyword.get(opts, :force, false)
    # CX-o3r7: forward signing_context (when present) to the underlying
    # CommitStoreClient.create_chained_commit/5 so MCP-initiated writes can
    # be signed by the session's bound key instead of inheriting the global
    # SecretStore. Absent → CommitStore falls back to its default behavior
    # (global key, or unsigned if no key configured).
    commit_opts = Keyword.take(opts, [:signing_context])
    args = %{"uuid" => uuid, "new_bytes" => byte_size(new_content)}

    result =
      Events.run("write", args, fn ->
        case DocBuilder.reconstruct_snapshot(state.store, uuid) do
          {:ok, doc} ->
            type = ContentType.get_type(doc)

            cond do
              type == :text or type == nil ->
                # Same-shape write — Myers-diff onto the existing text.
                old_content = ContentType.get_content(doc) || ""
                doc = Diff.apply_diff(doc, old_content, new_content)
                update = Yelixer.Encoding.encode_update(doc)
                CommitStoreClient.create_chained_commit(state.store, uuid, update, %{}, commit_opts)

                audit = %{
                  "uuid" => uuid,
                  "old_bytes" => byte_size(old_content),
                  "new_bytes" => byte_size(new_content),
                  "forced" => false
                }

                {:ok, audit, audit}

              force? ->
                # CX-yfva: forced clobber. Diff doesn't make sense across
                # type changes (Myers-diff between a YMap and a text string
                # is undefined); we replace the doc wholesale by writing a
                # new text doc as the next commit on the chain. Convergence
                # follows reconstruct_snapshot semantics for schema/text
                # docs (latest commit wins).
                fresh = Yelixer.Doc.new()
                fresh = ContentType.create(fresh, :text, "(forced)")
                fresh = ContentType.insert_text(fresh, 0, new_content)
                update = Yelixer.Encoding.encode_update(fresh)
                CommitStoreClient.create_chained_commit(state.store, uuid, update, %{}, commit_opts)

                audit = %{
                  "uuid" => uuid,
                  "old_bytes" => 0,
                  "new_bytes" => byte_size(new_content),
                  "forced" => true,
                  "previous_type" => Atom.to_string(type)
                }

                {:ok, audit, audit}

              true ->
                # Default refuse path. Default-destructive behavior was a
                # footgun — agents could trash views, JSON, etc. with a
                # single tool call.
                {:error, {:type_mismatch, type}}
            end

          :none ->
            {:error, :not_found}
        end
      end)

    {:reply, result, state}
  end

  # Backward-compat: the pre-CX-yfva call shape was {:write, uuid, content}
  # without the opts list. Accept it and default opts = [].
  @impl true
  def handle_call({:write, uuid, new_content}, from, state) do
    handle_call({:write, uuid, new_content, []}, from, state)
  end

  @impl true
  def handle_call({:branch_set_sync, parent_uuid, name, sync?}, _from, state) do
    verb = if sync?, do: "branch_activate", else: "branch_deactivate"
    args = %{"parent_uuid" => parent_uuid, "name" => name}

    result =
      Events.run(verb, args, fn ->
        case DocBuilder.reconstruct_snapshot(state.store, parent_uuid) do
          {:ok, doc} ->
            case Schema.get_entry(doc, name) do
              {:ok, _entry} ->
                doc = Schema.set_sync(doc, name, sync?)
                update = Yelixer.Encoding.encode_update(doc)
                CommitStoreClient.create_chained_commit(state.store, parent_uuid, update)
                {:ok, %{"parent_uuid" => parent_uuid, "name" => name, "sync" => sync?}}

              :error ->
                {:error, :not_found}
            end

          :none ->
            {:error, :not_found}
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:gc, root_uuid}, _from, state) do
    args = %{"root_uuid" => root_uuid}

    result =
      Events.run("gc", args, fn ->
        report = GC.report(root_uuid, state.store)

        summary = %{
          "reachable_count" => report.reachable_count,
          "orphaned_count" => report.orphaned_count,
          "orphaned_uuids" => Enum.to_list(report.orphaned_uuids)
        }

        {:ok, summary}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_info({:fork_done, from, source_uuid, result}, state) do
    GenServer.reply(from, result)
    {:noreply, %{state | in_flight_forks: MapSet.delete(state.in_flight_forks, source_uuid)}}
  end

  # --- Merge report → audit-friendly summary ---

  defp merge_report_summary(%Merge.MergeReport{} = report) do
    %{
      "merged_count" => length(report.merged_docs),
      "new_count" => length(report.new_docs),
      "deleted_count" => length(report.deleted_docs),
      "conflict_count" => length(report.conflicts),
      "auto_renamed" =>
        Enum.map(report.auto_renamed, fn {:auto_renamed, original, renamed, _src, _new} ->
          %{"original" => original, "renamed" => renamed}
        end),
      "conflicts" =>
        Enum.map(report.conflicts, fn conflict ->
          inspect(conflict)
        end)
    }
  end
end
