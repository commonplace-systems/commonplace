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
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.View.ComputeRunner

  defstruct [
    :source_uuid,
    :target_uuid,
    :compute_fn,
    :code_uuid,
    :name,
    :router,
    :store,
    :last_computed_at
  ]

  @type t :: %__MODULE__{
          source_uuid: String.t(),
          target_uuid: String.t(),
          compute_fn: (term() -> term()),
          code_uuid: String.t() | nil,
          name: atom() | nil,
          router: GenServer.server(),
          store: GenServer.server(),
          last_computed_at: DateTime.t() | nil
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
        store: store
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
    {:noreply, do_compute(state)}
  end

  @impl true
  def handle_info({:commit, source_uuid, _commit_id, _meta}, %{source_uuid: source_uuid} = state) do
    {:noreply, do_compute(state)}
  end

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

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:recompute, _from, state) do
    new_state = do_compute(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # --- Private ---

  defp do_compute(%__MODULE__{} = state) do
    try do
      source_content = read_content(state.store, state.source_uuid)
      new_content = state.compute_fn.(source_content)

      case CommandRouter.write(state.router, state.target_uuid, new_content) do
        {:ok, info} ->
          Logger.debug(fn ->
            "ViewCompute #{inspect(state.name || state.source_uuid)}: wrote #{info["new_bytes"]} bytes to target (was #{info["old_bytes"]})"
          end)

        {:error, :not_found} ->
          Logger.warning(
            "ViewCompute #{inspect(state.name)}: target #{state.target_uuid} not found — view will not render until the target is created"
          )

        {:error, reason} ->
          Logger.error("ViewCompute #{inspect(state.name)}: write failed: #{inspect(reason)}")
      end

      %{state | last_computed_at: DateTime.utc_now()}
    rescue
      e ->
        Logger.error(
          "ViewCompute #{inspect(state.name)}: compute raised #{Exception.message(e)}"
        )

        state
    end
  end

  defp read_content(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc) || ""
      :none -> ""
    end
  end
end
