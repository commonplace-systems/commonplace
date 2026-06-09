defmodule Commonplace.CommandRouter do
  @moduledoc """
  The single observable command surface for all mutating verbs in
  Commonplace. Singleton `GenServer`: every `fork`, `merge`, `gc`,
  branch toggle, and `write` lands here, dispatches to the
  appropriate module, and emits a magenta event triple —
  `command.initiated` → `command.completed` or `command.failed` —
  via `Commonplace.CommandRouter.Events.run/3`.

  The CLI and the MCP server (and any future mutation caller) route
  through this module rather than calling `Commonplace.Tree.Fork`,
  `Commonplace.Tree.Merge`, `Commonplace.Store.GC`, or
  `Commonplace.Tree.Schema` directly. Anything that bypasses the
  router is invisible to the magenta channel and therefore absent
  from the workspace's reactive graph.

  ## Why this exists

  Commonplace uses a color-channel discipline — a set of named
  Phoenix.PubSub channels (red / blue / cyan / magenta / green),
  each carrying one class of observable workspace change so callers
  have a stable topic to subscribe to. Only two matter here:
  **magenta** carries live command/mutation events, and **red** is
  the durable audit chain that magenta feeds into. (The full channel
  vocabulary is defined in `Commonplace.Dataflow.Channel`.) The
  challenge is ensuring all mutations actually emit. Letting every
  caller fire its own magenta events
  fragments responsibility and creates gaps. Routing commands as
  magenta messages through a dedicated consumer would rebuild
  `GenServer.call` from scratch — request/reply over pub/sub with
  timeouts and back-pressure.

  CommandRouter splits the difference: `GenServer.call` handles
  request/reply; magenta events are a side-effect, wrapped once in
  `Events.run/3` rather than duplicated by callers.

  Magenta feeds the magenta→red onramp, which appends each command
  event to a red-channel audit chain. Gold-chain attestation
  (CX-9rl) — a hash-linked chain of signatures over those red
  entries, see `Commonplace.Gold.Chain` — happens downstream; the
  router itself does not sign.

  ## Public commands

  Five verbs make up the P1 router surface:

    - `fork/2` — DAG-branch a directory subtree. Delegates to
      `Commonplace.Tree.Fork.fork_directory/2`. Runs async via Task
      (see "Async fork" below).
    - `merge/3` — three-way CRDT merge from source into target.
      Delegates to `Commonplace.Tree.Merge.merge/3`. Returns a
      summary map suitable for audit-log inclusion.
    - `gc/2` — reachability garbage-collect from `root_uuid`.
      Delegates to `Commonplace.Store.GC.report/2`. Reports
      reachable and orphaned counts; the actual sweep is a separate
      operation.
    - `branch_activate/3` and `branch_deactivate/3` — flip the
      `:nosync` flag on a named child entry of `parent_uuid`. Both
      delegate to `Commonplace.Tree.Schema.set_sync/3`; the magenta
      verb name (`branch_activate` vs `branch_deactivate`) preserves
      user intent in the audit log rather than collapsing both to
      the underlying primitive.
    - `write/2..4` — Myers-diff smart-merge text update. Reads the
      doc's current content, builds a character-level edit script
      against `new_content`, applies it as a chained commit. The
      explicit-arity shape is CX-yfva — see below.

  ## Magenta event triple

  Every dispatch emits three events on the `__commands` magenta
  topic via `Events.run/3`:

      command.initiated   { verb, args, request_id }
      command.completed   { verb, args, request_id, result }
        — OR —
      command.failed      { verb, args, request_id, reason }

  The `request_id` is a unique identifier generated per dispatch
  that ties the triple together, so audit consumers can correlate
  `initiated` with its `completed`/`failed` across concurrent
  in-flight commands. The `args` map carries caller-supplied
  parameters (UUIDs, byte counts, etc.) for the audit record.

  Magenta is **best-effort** — `Events.run/3` does not block on
  the PubSub broadcast. Subscribers that crash mid-event will miss
  it. The gold chain (red-channel audit) is the durable record;
  magenta is the live signal.

  ## Async fork (CX-kqz3)

  `fork/2` is the only async verb. The handler:

    1. Checks `state.in_flight_forks`. If a fork from this source
       is already running, returns `{:error, :fork_in_progress}`
       immediately, rejecting the duplicate.
    2. Otherwise marks the source as in-flight, spawns a `Task`
       for the actual fork work, and returns `{:noreply, ...}`.
       The GenServer stays responsive to other commands while the
       fork runs.
    3. When the Task finishes, it sends `{:fork_done, from, ...}`
       back to the router. `handle_info/2` replies to the original
       caller and clears the in-flight flag.

  Why async, and why deduplicate? CX-kqz3's root cause: an MCP
  escript whose first fork call timed out at the default 5s
  `GenServer.call` timeout would retry, queuing duplicate fork
  work behind the first. Under repeated retries all schedulers
  pinned on serial fork work, `net_kernel`'s heartbeat starved,
  and the escript saw the server node as `:nodedown` — even though
  the node was alive. The Task keeps the router responsive; the
  in-flight `MapSet` rejects retries before they join the queue.
  `@fork_call_timeout` of 30s gives a deep-tree fork enough runway
  without reopening that retry storm.

  All other verbs are synchronous. Fork is the only one slow
  enough to need this treatment.

  ## Explicit-arity `write/2..4` (CX-yfva)

  `write` is defined as four explicit clauses rather than one
  function with two default parameters. The compact form —

      def write(server \\\\ __MODULE__, uuid, new_content, opts \\\\ [])

  — is ambiguous when called with three positional arguments.
  Elixir's compiler expands defaults left-to-right, so:

      write(uuid, new_content, opts)

  binds `server = uuid`, `uuid = new_content`, `new_content = opts`.
  The `GenServer.call` then targets a UUID binary instead of a
  registered process name and crashes inside MCP's tool dispatch
  with a `FunctionClauseError`.

  The fix: explicit clauses for the four valid call shapes —
  `uuid + content`, `uuid + content + opts`, `server + uuid +
  content`, `server + uuid + content + opts` — each delegating to
  the canonical four-arg form. The compiler dispatches on arity;
  no ambiguous default expansion.

  ## Force-overwrite and type guard on `write` (CX-yfva)

  When the target doc's content type is not `:text`, `write`
  returns `{:error, {:type_mismatch, actual_type}}` by default.
  Silently overwriting a view doc, JSON config, or binary
  attachment with raw text was a footgun for agent-issued tool
  calls. The guard refuses unless the caller explicitly passes
  `force: true`.

  `force: true` is opt-in destruction: the handler builds a fresh
  text doc holding `new_content` as the next commit in the chain,
  discarding the prior content variant. Convergence follows
  `DocBuilder.reconstruct_snapshot/2` semantics (latest commit
  wins). Intended for administrative rewrites where the caller
  knows what they are replacing.

  ## Signing-context forwarding (CX-o3r7)

  When `opts` includes `signing_context: <key_id>`, that value is
  forwarded to `CommitStoreClient.create_chained_commit/5`. MCP-bound
  sessions can thereby sign commits with the session's own key
  rather than inheriting the global `SecretStore` key. If absent,
  CommitStore falls back to its configured default (global key, or
  unsigned if none is set).

  This is the only point at which CommandRouter touches signing —
  a one-line passthrough, not a signing decision.

  ## Interaction with sister modules

  - `Commonplace.Tree.Schema` — `branch_activate`/`branch_deactivate`
    delegate to `Schema.set_sync/3` after fetching the parent schema
    via `DocBuilder.reconstruct_snapshot/2`. CommandRouter owns the
    event triple and the entry-existence check; Schema owns the flag
    flip. (See `Tree.Schema`'s "sync flag" section for per-entry
    semantics.)
  - `Commonplace.Tree.Fork` — `fork/2` delegates to
    `Fork.fork_directory/2`. CommandRouter owns in-flight dedup,
    Task lifecycle, and magenta wrapping; the deep-copy logic lives
    in Fork. (See `Tree.Fork`'s "DAG branch structure" section for
    what a fork actually produces.)
  - `Commonplace.Tree.Merge` — `merge/3` delegates to
    `Merge.merge/3`; CommandRouter projects the `MergeReport` to a
    flat, audit-friendly summary map.
  - `Commonplace.Store.GC` — `gc/2` delegates to `GC.report/2`.
  - `Commonplace.Document.Diff` — `write/2..4` uses
    `Diff.apply_diff/3` for the Myers-diff character-level edit.

  ## Invariants

    - **Every dispatch emits a complete event triple.** Either
      `initiated → completed` or `initiated → failed` — never
      just `initiated`. `Events.run/3` enforces this via
      try/rescue; even an unexpected exception lands as a `failed`
      event.
    - **One fork in flight per source UUID.** `in_flight_forks`
      blocks duplicates; a second concurrent caller for the same
      source receives `{:error, :fork_in_progress}` immediately.
    - **`:type_mismatch` is the default-refuse on non-text writes.**
      No silent clobber of structured docs.
    - **Magenta is best-effort; gold chain is the durable record.**
      A subscriber that drops events sees gaps; the audit consumer
      reading the red→gold chain is canonical.

  ## What this module is NOT

  - **Not a transport.** Magenta broadcasts go via Phoenix.PubSub;
    the wire is the caller's concern.
  - **Not the persistence layer.** Commits are written by
    `CommitStoreClient`; the router orchestrates the write but
    does not own storage.
  - **Not the audit consumer.** Magenta events originate here;
    the magenta→red onramp and gold-chain attestation live
    downstream.
  - **Not the only mutation surface.** Internal modules that
    bypass the router (e.g. live actor-presence files written via
    `Commonplace.Presence.create/3`) skip magenta events
    deliberately — they're trusted internal paths whose events
    would be noise. New external mutation surfaces should route
    through here.
  """

  use GenServer
  require Logger

  alias Commonplace.CommandRouter.Events
  alias Commonplace.Document.{ContentType, Diff}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.GC
  alias Commonplace.Tree.{DocBuilder, Fork, Merge, Schema}

  # in_flight_forks: MapSet of source UUIDs with a fork currently running.
  # Deduplicates concurrent requests on the same source (CX-kqz3 diagnosis —
  # see "Async fork" in the moduledoc).
  defstruct store: nil, in_flight_forks: MapSet.new()

  # 30s: the outer client's deadline for a fork call. The default 5s was
  # too tight under MCP load and invited the retry storm CX-kqz3 fixed.
  # The Task runs the actual work; this timeout is how long the caller
  # waits before giving up.
  @fork_call_timeout 30_000

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  DAG-branch a directory subtree rooted at `source_uuid`.
  Returns `{:ok, new_uuid}` or `{:error, reason}`.
  Returns `{:error, :fork_in_progress}` if a fork from this source
  is already running (CX-kqz3 in-flight dedup).
  """
  def fork(server \\ __MODULE__, source_uuid) do
    GenServer.call(server, {:fork, source_uuid}, @fork_call_timeout)
  end

  @doc """
  Three-way CRDT merge from `source_uuid` into `target_uuid`.
  Returns `{:ok, summary_map}` or `{:error, reason}`.
  Summary map keys: `"merged_count"`, `"new_count"`, `"deleted_count"`,
  `"conflict_count"`, `"auto_renamed"` (list of maps), `"conflicts"` (list).
  """
  def merge(server \\ __MODULE__, source_uuid, target_uuid) do
    GenServer.call(server, {:merge, source_uuid, target_uuid})
  end

  @doc """
  Reachability GC scan starting from `root_uuid`.
  Returns `{:ok, report_map}` with keys `"reachable_count"`,
  `"orphaned_count"`, and `"orphaned_uuids"` (list of strings).
  Reports only — the actual sweep is a separate operation.
  """
  def gc(server \\ __MODULE__, root_uuid) do
    GenServer.call(server, {:gc, root_uuid})
  end

  @doc """
  Enable sync on a named child directory of `parent_uuid` (sets `:nosync`
  false, so the sync agent exports it to disk).
  Returns `{:ok, %{parent_uuid, name, sync: true}}` or `{:error, :not_found}`.
  """
  def branch_activate(server \\ __MODULE__, parent_uuid, name) do
    GenServer.call(server, {:branch_set_sync, parent_uuid, name, true})
  end

  @doc """
  Disable sync on a named child directory of `parent_uuid` (sets `:nosync`
  true, so the sync agent stops exporting it to disk).
  Returns `{:ok, %{parent_uuid, name, sync: false}}` or `{:error, :not_found}`.
  """
  def branch_deactivate(server \\ __MODULE__, parent_uuid, name) do
    GenServer.call(server, {:branch_set_sync, parent_uuid, name, false})
  end

  @doc """
  Update the text content of a doc to `new_content` using a Myers-diff
  smart merge: builds a character-level insert/delete script against the
  current content and applies it as a chained commit, so concurrent CRDT
  edits are preserved.

  Returns `{:ok, audit_map}` with keys `"uuid"`, `"old_bytes"`,
  `"new_bytes"`, `"forced"`.

  Returns `{:error, :not_found}` if the doc does not exist.

  Returns `{:error, {:type_mismatch, actual_type}}` if the doc's content
  type is not `:text` and `force: false` (the default). Pass `force: true`
  to rebuild the doc as a fresh text doc (opt-in destruction — see
  "Force-overwrite and type guard" in the moduledoc).

  Pass `signing_context: key_id` in `opts` to sign the commit with a
  specific key (CX-o3r7 — see "Signing-context forwarding" in the moduledoc).
  """
  # CX-yfva: explicit clauses instead of two non-adjacent defaults.
  # `def write(server \\ __MODULE__, uuid, new_content, opts \\ [])` caused
  # arity-3 calls to bind server=uuid — see moduledoc for the full story.
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
        # CX-kqz3: reject the duplicate immediately. The caller gets an
        # in-band MCP error; crucially, the retry does not queue behind
        # the running fork inside CommitStore.
        {:reply, {:error, :fork_in_progress}, state}

      true ->
        store = state.store
        router = self()

        # Spawn the fork work on a Task so the GenServer stays responsive
        # (and can reject duplicates) while this fork runs.
        # Reply arrives via the {:fork_done, ...} info message.
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
    # CX-o3r7: pass signing_context through to CommitStoreClient so
    # MCP-initiated writes can sign with the session's key. Absent →
    # CommitStore falls back to its default (global key or unsigned).
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
                # CX-yfva forced clobber. Myers-diff across a type boundary
                # (YMap vs text) is undefined, so we replace wholesale: write
                # a fresh text doc as the next commit on the chain.
                # Convergence follows reconstruct_snapshot semantics —
                # latest commit wins.
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
                # Default-refuse: silently clobbering views or JSON with raw
                # text was a footgun. Caller must opt in with force: true.
                {:error, {:type_mismatch, type}}
            end

          :none ->
            {:error, :not_found}
        end
      end)

    {:reply, result, state}
  end

  # Backward-compat: pre-CX-yfva callers sent {:write, uuid, content}
  # without an opts list. Accept and default opts to [].
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
