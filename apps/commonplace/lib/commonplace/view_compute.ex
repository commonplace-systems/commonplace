defmodule Commonplace.ViewCompute do
  @moduledoc """
  A minimal reactive compute loop for Views (CX-d4q / Pass B).

  A `ViewCompute` GenServer watches a source document via Phoenix PubSub
  and recomputes a target view document whenever the source changes.
  This is the "live" half of computed views: when a human edits the
  source markdown in a wiki LiveView, the subscribed ViewCompute picks
  up the commit, runs its transformation function, and writes the
  result to the target view doc via `Commonplace.CommandRouter.write/3`
  — the same CRDT-safe merge call site as MCP `write`.

  ## Why not `Commonplace.SmartDoc`?

  The longer-term home for this kind of reactive wiring is a
  `Commonplace.SmartDoc` managed by `Commonplace.Process.Orchestrator`,
  registered via a `__processes.json` entry co-located with the view.
  That path has known gaps today:

  * `SmartDoc.handle_blue/2` is called by the Orchestrator as a
    stateless module function (not a GenServer.call on the SmartDoc's
    own process), so it has no access to resolved cyan ports.
  * `Commonplace.SmartDoc.push_cyan/3` has zero callers and isn't
    wired to anything.
  * `Commonplace.Process.Orchestrator` is not in the application
    supervision tree and only runs when started explicitly.

  Fixing those is a medium refactor. Pass B ships a working reactive
  view without blocking on it. Later phases generalize the
  `ViewCompute` pattern into an Orchestrator-spawned SmartDoc flavor;
  existing callers migrate mechanically.

  ## Two ways to supply the computation

  Exactly one of two mutually-exclusive opts resolves the transformation
  (`init/1` validates, and stops with an error if neither or both are
  given):

  * `:compute_fn` — a direct closure (the legacy path, still
    first-class). Used in the examples below.
  * `:code_uuid` — the UUID of an Elixir *source-code document* in the
    tree; the computation is whatever pipeline that doc compiles to, run
    via `Commonplace.View.ComputeRunner`. `init/1` wraps it in a
    `compute_fn` with the identical shape, so everything downstream is
    the same. This is the M7 path (CX-pcn4) that lets the computation
    *itself* be substrate-defined and editable — the transform is a code
    doc like any other.

  These create two independent reactivity axes (see Lifecycle): editing
  the *source content* reruns the compute; editing the *code doc*
  re-derives the compute itself.

  ## Compute function shape

  Whichever source supplied it, `compute_fn` is a 1-arity function
  taking the source doc's current text content (a string — what
  `ContentType.get_content/1` returns) and returning the target doc's
  new text content (a string). Pure and synchronous — no IO, no
  ownership of state beyond its inputs.

  For a wiki-home style view:

      compute_fn = fn source_markdown ->
        CommonplaceWebWeb.ViewBuild.wrap_markdown_as_view(source_markdown)
      end

  ## Lifecycle

  Started with `start_link/1` and the required opts:

      Commonplace.ViewCompute.start_link(
        name: MyWatcher,
        source_uuid: "abc-...",
        target_uuid: "def-...",
        compute_fn: &MyModule.compute/1
      )

  The GenServer subscribes to the `blue:<source_uuid>` PubSub topic
  (the same topic `Commonplace.Store.CommitStore` broadcasts to on
  commit). On each incoming `{:commit, source_uuid, _commit_id, _meta}`
  message, it reads the current source content, applies `compute_fn`,
  and writes the result to the target via `CommandRouter.write/3`.
  If the computed result equals the current target content, no commit
  is created — `CommandRouter.write` already has that short-circuit
  because `Diff.apply_diff/3` produces an empty op list on no-op.

  When started with `:code_uuid`, the server *also* subscribes to
  `blue:<code_uuid>`. A commit there means the computation's definition
  changed, not its input — so the server stops `:normal` and lets its
  supervisor restart it, which re-resolves and recompiles the code doc
  from scratch (CX-wxbp / CX-6fhe). This is eventually consistent:
  several near-simultaneous code commits collapse into a single restart
  cycle, because stop messages delivered to the already-dead process are
  ignored.
  """

  use GenServer
  require Logger

  alias Commonplace.CommandRouter
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.DerivationRecord
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.View.ComputeRunner

  # R6 (CX-tdkq.6) backpressure + loop-safety defaults.
  @default_compute_timeout_ms 10_000
  # A view recomputing faster than this within the window is in a cycle, not
  # responding to human edits — trip the fuse. Generous so legitimate edit
  # bursts (already collapsed by coalescing) never trip it; only a tight
  # self-feeding loop sustains this rate.
  @default_fuse_max 50
  @default_fuse_window_ms 1_000

  defstruct [
    :source_uuid,
    :target_uuid,
    :compute_fn,
    :code_uuid,
    :name,
    :router,
    :store,
    :last_computed_at,
    # CX-vt9l.2: derivation record for the most recent successful write
    # (nil until the first compute completes) — see
    # `Commonplace.DerivationRecord`. Additive: nothing existing reads
    # this field; it rides alongside `last_computed_at`, which stays
    # unchanged.
    :derivation_record,
    # R6: async single-flight + coalesce
    :computing,
    pending: false,
    # R6: rate fuse
    recompute_log: [],
    tripped: false,
    # R6: config
    compute_timeout_ms: @default_compute_timeout_ms,
    fuse_max: @default_fuse_max,
    fuse_window_ms: @default_fuse_window_ms
  ]

  @type t :: %__MODULE__{
          source_uuid: String.t(),
          target_uuid: String.t(),
          compute_fn: (term() -> term()),
          code_uuid: String.t() | nil,
          name: atom() | nil,
          router: GenServer.server(),
          store: GenServer.server(),
          last_computed_at: DateTime.t() | nil,
          derivation_record: DerivationRecord.t() | nil,
          computing: {pid(), reference(), reference()} | nil,
          pending: boolean(),
          recompute_log: [integer()],
          tripped: boolean(),
          compute_timeout_ms: pos_integer(),
          fuse_max: pos_integer(),
          fuse_window_ms: pos_integer()
        }

  # --- Client API ---

  @doc """
  Start a ViewCompute GenServer watching `source_uuid` and writing
  recomputed content to `target_uuid` via `compute_fn`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc """
  Force a recompute even if no commit arrived. Useful after seeding
  or for tests that want to verify the compute loop without waiting
  for a commit broadcast.
  """
  def recompute(server) do
    GenServer.call(server, :recompute)
  end

  @doc """
  Get the current state (for tests and smoke checks).
  """
  def state(server) do
    GenServer.call(server, :state)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    source_uuid = Keyword.fetch!(opts, :source_uuid)
    target_uuid = Keyword.fetch!(opts, :target_uuid)
    name = Keyword.get(opts, :name)
    router = Keyword.get(opts, :router, CommandRouter)
    store = Keyword.get(opts, :store, CommitStoreClient)

    # CX-pcn4 (M7 sub-bead v): two mutually-exclusive opts for compute
    # resolution after M5/M6 XML compute-spec form deletion:
    #   :compute_fn — direct closure (legacy; still first-class)
    #   :code_uuid  — M7 Elixir-source-as-pipeline code-doc via ComputeRunner
    # Exactly one must be supplied; init/1 validates.
    compute_fn_opt = Keyword.get(opts, :compute_fn)
    code_uuid_opt = Keyword.get(opts, :code_uuid)

    with {:ok, {compute_fn, code_uuid}} <-
           resolve_compute(compute_fn_opt, code_uuid_opt, opts, store) do
      CPPubSub.subscribe_blue(source_uuid)
      if code_uuid, do: CPPubSub.subscribe_blue(code_uuid)

      state = %__MODULE__{
        source_uuid: source_uuid,
        target_uuid: target_uuid,
        compute_fn: compute_fn,
        code_uuid: code_uuid,
        name: name,
        router: router,
        store: store,
        compute_timeout_ms: Keyword.get(opts, :compute_timeout_ms, @default_compute_timeout_ms),
        fuse_max: Keyword.get(opts, :fuse_max, @default_fuse_max),
        fuse_window_ms: Keyword.get(opts, :fuse_window_ms, @default_fuse_window_ms)
      }

      send(self(), :initial_compute)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp resolve_compute(nil, nil, _opts, _store) do
    {:error, "must supply exactly one of :compute_fn or :code_uuid"}
  end

  defp resolve_compute(fn_opt, nil, _opts, _store) when is_function(fn_opt, 1) do
    {:ok, {fn_opt, nil}}
  end

  defp resolve_compute(nil, code_uuid, opts, store) when is_binary(code_uuid) do
    spec_context = Keyword.get(opts, :spec_context, %{})

    with :ok <- ComputeRunner.validate(code_uuid, store) do
      compute_fn = fn raw_input ->
        case ComputeRunner.compute(code_uuid, raw_input, spec_context, store) do
          {:ok, output} -> output
          {:error, reason} -> raise "ComputeRunner failed: #{inspect(reason)}"
        end
      end

      {:ok, {compute_fn, code_uuid}}
    end
  end

  defp resolve_compute(_, _, _, _) do
    {:error, "must supply exactly one of :compute_fn or :code_uuid (not both)"}
  end

  @impl true
  def handle_info(:initial_compute, state) do
    {:noreply, request_compute(state)}
  end

  @impl true
  def handle_info({:commit, source_uuid, _commit_id, _meta}, %{source_uuid: source_uuid} = state) do
    # R6: a source commit requests a recompute. request_compute coalesces
    # (single-flight + pending) and trips the rate fuse on a runaway loop.
    {:noreply, request_compute(state)}
  end

  # R6: the async compute task finished (or was killed by the timeout).
  @impl true
  def handle_info(
        {:DOWN, ref, :process, _down_pid, reason},
        %{computing: {_pid, ref, timer}} = state
      ) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    case reason do
      r when r in [:normal, :killed] ->
        :ok

      other ->
        Logger.error("ViewCompute #{inspect(state.name)}: compute task exited #{inspect(other)}")
    end

    state = %{state | computing: nil, last_computed_at: DateTime.utc_now()}

    # Coalesced request(s) arrived while we were computing — run exactly one
    # more against the now-latest state.
    if state.pending do
      {:noreply, start_compute(%{state | pending: false})}
    else
      {:noreply, state}
    end
  end

  # R6: the in-flight compute overran its timeout — kill it. The {:DOWN, ...}
  # that follows (reason :killed) does the bookkeeping + drains any pending.
  @impl true
  def handle_info({:compute_timeout, ref}, %{computing: {pid, ref, _timer}} = state) do
    Logger.error(
      "ViewCompute #{inspect(state.name)}: compute exceeded #{state.compute_timeout_ms}ms — killing"
    )

    :telemetry.execute(
      [:commonplace, :view_compute, :compute_timeout],
      %{system_time: System.system_time()},
      %{name: state.name, source_uuid: state.source_uuid, target_uuid: state.target_uuid}
    )

    Process.exit(pid, :kill)
    {:noreply, state}
  end

  # Stale DOWN / timeout for a compute we already finished — ignore.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:compute_timeout, _ref}, state), do: {:noreply, state}

  # CX-wxbp (M5 sub-bead iii) + CX-6fhe (M6 sub-bead iii):
  # Restart-on-spec-or-code-commit. Either the spec doc OR any
  # subscribed code doc (M6 <function ref> targets) receiving a new
  # commit triggers {:stop, :normal} — supervisor restarts which
  # re-reads spec + re-resolves refs + re-compiles via SourceDoc
  # (recompile triggered by new content_hash). Eventually consistent:
  # simultaneous commits result in a single restart cycle (subsequent
  # stop messages on dead process are ignored).
  @impl true
  def handle_info({:commit, uuid, _commit_id, _meta}, state) when is_binary(uuid) do
    if uuid == state.code_uuid do
      Logger.debug(fn ->
        "ViewCompute #{inspect(state.name || state.source_uuid)}: code doc #{uuid} updated — restarting"
      end)

      {:stop, :normal, state}
    else
      # Not our source / not our code — ignore.
      {:noreply, state}
    end
  end

  # CX-vt9l.2: do_compute_work (inline or the spawned task) reports its
  # freshly-built derivation record back here rather than returning it —
  # the async path has no return channel to the GenServer. Additive:
  # `last_computed_at` is set at the call site exactly as before; this
  # only ever adds `derivation_record` alongside it.
  @impl true
  def handle_info({:derivation_record, target_uuid, record}, %{target_uuid: target_uuid} = state) do
    {:noreply, %{state | derivation_record: record}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # recompute/1 is an explicit, synchronous force (tests + seeding). It runs
  # the compute inline and bypasses the async/coalesce/fuse machinery on
  # purpose — it's an out-of-band manual trigger, not the reactive path.
  @impl true
  def handle_call(:recompute, _from, state) do
    do_compute_work(state, self())
    {:reply, :ok, %{state | last_computed_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # --- Private: R6 scheduling (async single-flight + coalesce + rate fuse) ---

  # Request a recompute. If the fuse is tripped, do nothing. If a compute is
  # already running, mark a single coalesced re-run (collapsing a burst of N
  # source commits into one recompute against the latest state — the read
  # side tolerates this). Otherwise start one.
  defp request_compute(%__MODULE__{tripped: true} = state), do: state

  defp request_compute(%__MODULE__{computing: c} = state) when c != nil,
    do: %{state | pending: true}

  defp request_compute(%__MODULE__{} = state), do: start_compute(state)

  defp start_compute(%__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)
    log = [now | state.recompute_log] |> Enum.filter(&(now - &1 < state.fuse_window_ms))

    if length(log) > state.fuse_max do
      trip_fuse(state, length(log))
    else
      # Run the compute in a monitored process so a slow/hanging/raising
      # compute_fn (e.g. arbitrary substrate code via ComputeRunner) can't
      # block this GenServer — it stays responsive to coalesce further
      # requests. The timer enforces the timeout.
      parent = self()
      {pid, ref} = spawn_monitor(fn -> do_compute_work(state, parent) end)
      timer = Process.send_after(self(), {:compute_timeout, ref}, state.compute_timeout_ms)
      %{state | computing: {pid, ref, timer}, recompute_log: log, pending: false}
    end
  end

  defp trip_fuse(%__MODULE__{} = state, rate) do
    Logger.error(
      "ViewCompute #{inspect(state.name || state.source_uuid)}: recompute rate fuse tripped " <>
        "(>#{state.fuse_max} recomputes / #{state.fuse_window_ms}ms) — likely a reactive cycle. " <>
        "Halting recomputes; restart the view after breaking the loop."
    )

    :telemetry.execute(
      [:commonplace, :view_compute, :fuse_tripped],
      %{rate: rate},
      %{name: state.name, source_uuid: state.source_uuid, target_uuid: state.target_uuid}
    )

    %{state | tripped: true, computing: nil, pending: false}
  end

  # The actual computation: read latest source, transform, write target.
  # Runs in the async task (reactive path) or inline (recompute/1). Returns
  # :ok; never lets a compute_fn raise escape uncaught on the inline path.
  # `reply_to` is the ViewCompute GenServer's own pid — needed so the
  # CX-vt9l.2 derivation-record message (sent only on a successful write)
  # reaches the right process even when this runs in a spawned task.
  defp do_compute_work(%__MODULE__{} = state, reply_to) do
    try do
      source_content = read_content(state.store, state.source_uuid)
      new_content = state.compute_fn.(source_content)

      case CommandRouter.write(state.router, state.target_uuid, new_content) do
        {:ok, info} ->
          Logger.debug(fn ->
            "ViewCompute #{inspect(state.name || state.source_uuid)}: wrote #{info["new_bytes"]} bytes to target (was #{info["old_bytes"]})"
          end)

          emit_derivation_record(state, reply_to)

        {:error, :not_found} ->
          Logger.warning(
            "ViewCompute #{inspect(state.name)}: target #{state.target_uuid} not found — view will not render until the target is created"
          )

        {:error, reason} ->
          Logger.error("ViewCompute #{inspect(state.name)}: write failed: #{inspect(reason)}")
      end

      :ok
    rescue
      e ->
        Logger.error("ViewCompute #{inspect(state.name)}: compute raised #{Exception.message(e)}")

        :ok
    end
  end

  # CX-vt9l.2 adoption (see docs/derivation-records.md): builds and posts a
  # `Commonplace.DerivationRecord` for the write that just succeeded.
  # `sources_pin` and `output` are each re-read via a SEPARATE
  # `latest_commit` call after the write, rather than threaded through
  # from the read/write above — that is a deliberate best-effort
  # approximation (there is a small window where a concurrent writer
  # could move the source between the content read and this read), not
  # an atomic transaction. Good enough for provenance labeling; not a
  # correctness primitive. Never blocks or fails the write path — a
  # `latest_commit` miss just yields an empty/`nil` ref, it does not
  # raise.
  defp emit_derivation_record(state, reply_to) do
    sources_pin =
      case CommitStoreClient.latest_commit(state.store, state.source_uuid) do
        {:ok, commit} -> %{state.source_uuid => commit.id}
        :none -> %{}
      end

    output_ref =
      case CommitStoreClient.latest_commit(state.store, state.target_uuid) do
        {:ok, commit} -> {state.target_uuid, commit.id}
        :none -> nil
      end

    transform_ref = state.code_uuid || :inline_compute_fn
    record = DerivationRecord.new(sources_pin, transform_ref, output_ref)

    send(reply_to, {:derivation_record, state.target_uuid, record})
  end

  defp read_content(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc) || ""
      :none -> ""
    end
  end
end
