defmodule Commonplace.CommandRouter do
  @moduledoc """
  The single observable command surface for every mutating verb in
  Commonplace. Singleton `GenServer`; every `fork`, `merge`, `gc`,
  branch toggle, and `write` lands here, gets dispatched, and emits
  a `command.initiated` → `command.completed`/`command.failed`
  magenta event triple around the handler.

  The CLI and the MCP server (and any future caller that mutates
  state) call through this router rather than calling the
  underlying modules — `Commonplace.Tree.Fork`,
  `Commonplace.Tree.Merge`, `Commonplace.Store.GC`,
  `Commonplace.Tree.Schema` — directly. Anything that *isn't*
  routed through here is invisible to magenta and therefore
  invisible to the rest of the workspace's reactive graph.

  ## Why this exists

  Commonplace's color-channel discipline (red / blue / cyan /
  magenta / green) gives every observable change in the workspace
  a topic to subscribe to. The hard part is making sure all
  mutations are observable. The naive choice — let every caller
  fire its own magenta events — fragments responsibility and lets
  ad-hoc paths skip the broadcast. The pure-magenta choice — route
  every command request as a magenta message and have a dedicated
  consumer dispatch them — would rebuild `GenServer.call` from
  scratch (request/reply over pub/sub, with timeouts and
  back-pressure).

  CommandRouter splits the difference: native `GenServer.call` for
  the request/reply path, magenta events emitted as a side-effect.
  The single GenServer is the chokepoint; the magenta broadcasts
  are wrapped around each handler by `Commonplace.CommandRouter.Events.run/3`,
  not duplicated by callers.

  Magenta is itself the input to the magenta→red onramp, which
  appends each command event to a red-channel audit chain.
  Gold-chain attestation (CX-9rl) signs the resulting red entries
  downstream of CommandRouter; the router itself does not sign.

  ## Public commands

  Five verbs make up the P1 router surface:

    - `fork/2` — DAG-branch a directory subtree. Delegates to
      `Commonplace.Tree.Fork.fork_directory/2`. Async via Task
      (see "Async fork" below).
    - `merge/3` — three-way CRDT merge into a target subtree.
      Delegates to `Commonplace.Tree.Merge.merge/3`. Returns a
      summary map suitable for audit-log inclusion.
    - `gc/2` — reachability garbage-collect from `root_uuid`.
      Delegates to `Commonplace.Store.GC.report/2`. Read-only-ish
      audit (the actual sweep is a separate operation).
    - `branch_activate/3` and `branch_deactivate/3` — flip the
      `:nosync` flag on a named child entry of `parent_uuid`. Both
      route through `Commonplace.Tree.Schema.set_sync/3`; the
      magenta verb name distinguishes them so audit consumers see
      the user intent, not just the underlying primitive.
    - `write/2..4` — Myers-diff smart-merge text update. Reads the
      doc's current content, builds a character-level edit script
      against `new_content`, applies it as a chained commit. The
      multi-arity dance is CX-yfva — see below.

  ## Magenta event triple

  Every dispatch produces three events on the `__commands` magenta
  topic, wrapped by `Events.run/3`:

      command.initiated   { verb, args, request_id }
      command.completed   { verb, args, request_id, result }
        — OR —
      command.failed      { verb, args, request_id, reason }

  The `request_id` ties the triple together so a downstream audit
  consumer can match an `initiated` to its `completed`/`failed`
  even with concurrent dispatches in flight. The `args` map carries
  what the caller asked for (UUIDs, byte counts, etc.); audit
  consumers redact or transform it as needed.

  Magenta is **best-effort** — `Events.run/3` doesn't block on the
  PubSub broadcast. A subscriber that crashed mid-event will miss
  it; the gold-chain audit is the durable record, not magenta.

  ## Async fork (CX-kqz3)

  `fork/2` is the only async verb in the router. The handler:

    1. Checks `state.in_flight_forks` — if a fork of this source
       is already running, returns `{:error, :fork_in_progress}`
       immediately and rejects the duplicate.
    2. Otherwise, marks the source as in-flight and spawns a
       `Task` to do the actual fork work.
    3. Returns `{:noreply, ...}` — the GenServer is free to
       process other commands while the fork runs.
    4. When the Task finishes, it sends `{:fork_done, from, ...}`
       back to the router; `handle_info/2` then replies to the
       original caller and clears the in-flight flag.

  Why async, why dedup? CX-kqz3's diagnosis: an MCP escript whose
  first fork call timed out at the default 5s `GenServer.call`
  timeout would retry, queuing duplicate fork work behind the
  first. Under repeat retry, all schedulers pinned on serial fork
  work; `net_kernel`'s heartbeat starved; and the escript saw the
  serve node as `:nodedown` even though it was alive. The Task
  pattern lets the router stay responsive; the in-flight set
  rejects the retries before they re-enter the queue. The
  `@fork_call_timeout` of 30s gives a deep-tree fork enough
  runway without inviting that retry storm.

  All other verbs are synchronous — fork is the only one slow
  enough to need this treatment.

  ## The multi-arity `write/2..4` dance (CX-yfva)

  `write` has four explicit arities. Why not one definition with
  default params?

      def write(server \\\\ __MODULE__, uuid, new_content, opts \\\\ [])

  is what got bitten. Two non-adjacent `\\\\` defaults bracketing a
  positional argument is ambiguous to Elixir's compiler when called
  with three positional arguments:

      write(uuid, new_content, opts)

  binds `server = uuid`, `uuid = new_content`, `new_content = opts`
  — wrong dispatch. The `GenServer.call` then fires against a UUID
  string rather than a registered process name and crashes inside
  MCP's tool dispatch with a `FunctionClauseError`.

  The fix is explicit clauses for the four valid call shapes
  (`uuid + content`, `uuid + content + opts`, `server + uuid +
  content`, `server + uuid + content + opts`); each delegates to
  the four-arg form with the right defaults. No more ambiguous
  binding because the compiler dispatches on arity, not on
  default-param expansion.

  ## Force-overwrite and type guard on `write` (CX-yfva)

  `write` defaults to `{:error, {:type_mismatch, actual_type}}`
  when the target doc isn't text. Default-destructive behaviour
  was a footgun — an agent could trash a view doc, a JSON
  config, or a binary attachment with one tool call. The guard
  refuses unless the caller passes `force: true`.

  `force: true` is opt-in destruction: it rebuilds the doc as a
  fresh text doc holding `new_content`, drops the prior content
  variant. Convergence then follows
  `DocBuilder.reconstruct_snapshot/2` semantics (latest commit
  wins). Useful for "I know what I'm doing" administrative
  rewrites; not the default.

  ## Signing-context forwarding (CX-o3r7)

  When `write` is called with `signing_context: <key_id>` in
  opts, that context flows through to
  `CommitStoreClient.create_chained_commit/5`'s opts. MCP-bound
  sessions can sign their commits with the session's bound key
  rather than inheriting the global `SecretStore` key. Absent →
  the underlying CommitStore falls back to its default behaviour
  (global key, or unsigned if no key is configured).

  This is the only place CommandRouter touches signing — a
  one-line passthrough, not a signing decision.

  ## Interaction with sister modules

  - `Commonplace.Tree.Schema` — the `branch_activate`/`branch_deactivate`
    verbs delegate to `Schema.set_sync/3` after pulling the parent
    schema via `DocBuilder.reconstruct_snapshot/2`. CommandRouter
    owns the magenta event triple and the entry-existence check;
    the actual flag flip is Schema's primitive. (See `Tree.Schema`'s
    "sync flag" section for the per-entry semantics.)
  - `Commonplace.Tree.Fork` — `fork/2` delegates to
    `Fork.fork_directory/2`. CommandRouter owns the in-flight
    dedup, the Task management, and the magenta wrapping; the
    deep-copy itself lives in Fork. (See `Tree.Fork`'s "DAG branch
    structure" section for what the fork actually does.)
  - `Commonplace.Tree.Merge` — `merge/3` delegates to
    `Merge.merge/3`; CommandRouter projects the merge report to a
    flat audit-friendly summary map.
  - `Commonplace.Store.GC` — `gc/2` delegates to `GC.report/2`.
  - `Commonplace.Document.Diff` — `write/2..4` uses
    `Diff.apply_diff/3` for the Myers-diff merge.

  ## Invariants

    - **Every dispatch emits a complete event triple.** Either
      `initiated → completed` or `initiated → failed` — never just
      `initiated`. `Events.run/3` enforces this via try/rescue
      around the body; even an unexpected exception lands as a
      `failed` event.
    - **One fork in flight per source UUID.** `in_flight_forks`
      blocks duplicates; the second concurrent caller for the same
      source receives `{:error, :fork_in_progress}` immediately and
      doesn't queue work.
    - **`:type_mismatch` is the default-refuse on non-text
      writes.** No silent clobber of structured docs.
    - **Magenta is best-effort; gold chain is the durable record.**
      A subscriber that drops events sees gaps; the audit consumer
      that runs against the red→gold chain is the canonical one.

  ## What this module is NOT

  - **Not a transport.** Magenta broadcasts go via Phoenix.PubSub;
    the wire is the caller's concern.
  - **Not the persistence layer.** Commits are still written by
    `CommitStoreClient`; the router orchestrates the write but
    doesn't own the storage.
  - **Not the audit consumer.** Magenta events are emitted here;
    the magenta→red onramp and gold-chain attestation live
    downstream.
  - **Not the only mutation surface.** Internal modules that
    bypass the router (e.g. presence creation via
    `Commonplace.Presence.create/3`) skip the magenta events
    deliberately — they're trusted internal paths whose events
    would be noise. New external surfaces should go through the
    router.
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
