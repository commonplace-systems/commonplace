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

  ## Compute function shape

  The `compute_fn` is a 1-arity function taking the source doc's
  current text content (a string — what `ContentType.get_content/1`
  returns) and returning the target doc's new text content (a string).
  Pure and synchronous — no IO, no ownership of state beyond its
  inputs.

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
  """

  use GenServer
  require Logger

  alias Commonplace.CommandRouter
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  defstruct [:source_uuid, :target_uuid, :compute_fn, :name, :router, :store, :last_computed_at]

  @type t :: %__MODULE__{
          source_uuid: String.t(),
          target_uuid: String.t(),
          compute_fn: (String.t() -> String.t()),
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
    compute_fn = Keyword.fetch!(opts, :compute_fn)
    name = Keyword.get(opts, :name)
    router = Keyword.get(opts, :router, CommandRouter)
    store = Keyword.get(opts, :store, CommitStoreClient)

    CPPubSub.subscribe_blue(source_uuid)

    state = %__MODULE__{
      source_uuid: source_uuid,
      target_uuid: target_uuid,
      compute_fn: compute_fn,
      name: name,
      router: router,
      store: store
    }

    # Fire an initial recompute asynchronously so the target reflects
    # the current source state at startup. Use cast-to-self rather than
    # synchronous work in init/1 to avoid blocking start_link.
    send(self(), :initial_compute)

    {:ok, state}
  end

  @impl true
  def handle_info(:initial_compute, state) do
    {:noreply, do_compute(state)}
  end

  @impl true
  def handle_info({:commit, source_uuid, _commit_id, _meta}, %{source_uuid: source_uuid} = state) do
    {:noreply, do_compute(state)}
  end

  @impl true
  def handle_info({:commit, _other_uuid, _commit_id, _meta}, state) do
    # Not our source — ignore.
    {:noreply, state}
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
