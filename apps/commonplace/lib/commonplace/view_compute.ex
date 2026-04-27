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
  alias Commonplace.View.ComputeSpec

  defstruct [
    :source_uuid,
    :target_uuid,
    :compute_fn,
    :spec_uuid,
    :name,
    :router,
    :store,
    :last_computed_at,
    code_uuids: []
  ]

  @type t :: %__MODULE__{
          source_uuid: String.t(),
          target_uuid: String.t(),
          compute_fn: (term() -> term()),
          spec_uuid: String.t() | nil,
          name: atom() | nil,
          router: GenServer.server(),
          store: GenServer.server(),
          last_computed_at: DateTime.t() | nil,
          code_uuids: [String.t()]
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

    # CX-wxbp (M5 sub-bead iii): mutually-exclusive :compute_fn vs
    # :spec_uuid opts. Per round-1 Q5: validate exactly one supplied;
    # round-1 audit (I): malformed specs surface BEFORE compute-time
    # via ComputeSpec.validate.
    compute_fn_opt = Keyword.get(opts, :compute_fn)
    spec_uuid_opt = Keyword.get(opts, :spec_uuid)

    with {:ok, {compute_fn, spec_uuid, code_uuids}} <-
           resolve_compute(compute_fn_opt, spec_uuid_opt, opts, store) do
      CPPubSub.subscribe_blue(source_uuid)
      if spec_uuid, do: CPPubSub.subscribe_blue(spec_uuid)
      Enum.each(code_uuids, &CPPubSub.subscribe_blue/1)

      state = %__MODULE__{
        source_uuid: source_uuid,
        target_uuid: target_uuid,
        compute_fn: compute_fn,
        spec_uuid: spec_uuid,
        code_uuids: code_uuids,
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

  # Resolve the compute_fn from opts. Three branches:
  #   :compute_fn supplied (legacy direct-closure callers)
  #   :spec_uuid supplied — read + parse + validate spec; build closure
  #   neither / both — error
  defp resolve_compute(nil, nil, _opts, _store) do
    {:error, "must supply exactly one of :compute_fn or :spec_uuid"}
  end

  defp resolve_compute(compute_fn, nil, _opts, _store) when is_function(compute_fn, 1) do
    {:ok, {compute_fn, nil, []}}
  end

  defp resolve_compute(nil, spec_uuid, opts, store) when is_binary(spec_uuid) do
    spec_context = Keyword.get(opts, :spec_context, %{})
    # CX-7v9x (M6 sub-bead ii): validate may resolve M6 `<function ref>` forms
    # which need :spec_path. Threaded from spec_context if caller supplied it.
    spec_path = Map.get(spec_context, :spec_path)
    # CX-6fhe (M6 sub-bead iii): root_uuid for path-walking the resolved
    # ref to its source-doc UUID. Falls back to Workspace.root_uuid when
    # caller doesn't pass one (production path); tests with a custom
    # CommitStore pass it explicitly.
    root_uuid = Map.get(spec_context, :root_uuid)

    validate_opts =
      [store: store]
      |> maybe_kw_put(:spec_path, spec_path)

    with {:ok, content} <- read_spec_content(store, spec_uuid),
         {:ok, spec} <- ComputeSpec.parse(content),
         {:ok, validated_spec} <- ComputeSpec.validate(spec, validate_opts) do
      compute_fn = fn raw_input ->
        ComputeSpec.interpret(validated_spec, raw_input, spec_context)
      end

      # Extract code_uuids from M6 render steps' resolved refs.
      code_uuids = extract_code_uuids(validated_spec, spec_path, root_uuid, store)

      {:ok, {compute_fn, spec_uuid, code_uuids}}
    end
  end

  defp resolve_compute(_, _, _, _) do
    {:error, "must supply exactly one of :compute_fn or :spec_uuid (not both)"}
  end

  defp maybe_kw_put(kw, _key, nil), do: kw
  defp maybe_kw_put(kw, key, value), do: Keyword.put(kw, key, value)

  # CX-6fhe (M6 sub-bead iii): walk validated spec's pipeline; for each
  # M6 render step (carrying :ref), resolve the source-doc UUID via
  # SourceDoc-style path walk so ViewCompute can subscribe to its
  # commits. M5 render steps (no :ref) contribute no code_uuids.
  defp extract_code_uuids(_validated_spec, nil, _root_uuid, _store), do: []

  defp extract_code_uuids(validated_spec, spec_path, root_uuid, store)
       when is_binary(spec_path) do
    validated_spec.pipeline
    |> Enum.flat_map(fn
      %{kind: :render, ref: ref} when is_binary(ref) ->
        case resolve_ref_to_uuid(ref, spec_path, root_uuid, store) do
          {:ok, uuid} -> [uuid]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp resolve_ref_to_uuid(ref, spec_path, root_uuid, store) do
    parent = Path.dirname(spec_path)

    target_path =
      case ref do
        "../" <> rest ->
          if parent in [".", ""], do: rest, else: Path.join(parent, rest)

        "./" <> rest ->
          if parent in [".", ""], do: rest, else: Path.join(parent, rest)

        _ ->
          ref
      end

    with {:ok, root} <- resolve_root(root_uuid),
         {:ok, uuid} <-
           Commonplace.Tree.Lookup.lookup_doc_by_path(root, target_path, store: store) do
      {:ok, uuid}
    end
  end

  defp resolve_root(nil), do: Commonplace.Workspace.root_uuid()
  defp resolve_root(uuid) when is_binary(uuid), do: {:ok, uuid}

  defp read_spec_content(store, spec_uuid) do
    case DocBuilder.reconstruct_snapshot(store, spec_uuid) do
      {:ok, doc} ->
        case ContentType.get_content(doc) do
          nil -> {:error, "spec doc #{spec_uuid} is empty"}
          content -> {:ok, content}
        end

      :none ->
        {:error, "spec doc #{spec_uuid} not found"}
    end
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
    cond do
      uuid == state.spec_uuid ->
        Logger.debug(fn ->
          "ViewCompute #{inspect(state.name || state.source_uuid)}: spec doc #{uuid} updated — restarting"
        end)

        {:stop, :normal, state}

      uuid in state.code_uuids ->
        Logger.debug(fn ->
          "ViewCompute #{inspect(state.name || state.source_uuid)}: code doc #{uuid} updated — restarting"
        end)

        {:stop, :normal, state}

      true ->
        # Not our source / not our spec / not our code — ignore.
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
