defmodule Commonplace.Black.PatternCompute do
  @moduledoc """
  CX-o1l9 (Black M1, piece ii): pattern-scoped subscription — the new
  substrate mechanism the design brief calls "compute docs whose
  SOURCE is a pattern instead of an enumerated UUID list."

  `Commonplace.ViewCompute` (its `@moduledoc` explains the reactive
  loop this is a SIBLING of, not a modification of) watches exactly
  one `source_uuid`. `PatternCompute` watches a `Commonplace.Black`
  glob `pattern`, evaluated fresh against `root_uuid` at init and
  RE-EVALUATED on every schema-directory commit anywhere in the
  matched region — so the match SET, not a fixed doc list, is the
  reactive input.

  ## THE pin (spec §2): new docs matching after init recompute

  A doc created after `PatternCompute` starts, at a path that matches
  `pattern`, triggers a recompute WITHOUT any caller re-registering the
  subscription. This is what makes it "black" (pattern-driven) rather
  than just "watch these N docs" (which `ViewCompute` already does,
  one doc at a time). The mechanism: on init, `Commonplace.Black.select/3`
  is called with `with_dirs: true`, returning both the current match
  set AND the set of every directory schema doc visited during the
  walk. This server subscribes (blue) to every matched doc PLUS every
  visited directory. A new file added to an already-visited directory
  commits to THAT directory's schema doc — which this server is
  already subscribed to — so the directory-schema branch of
  `handle_info/2` fires, re-runs `select/3`, and picks up the new
  match.

  ## Subscription bookkeeping

  Two disjoint UUID sets are tracked:

    * `subscribed_docs` — the current match set's UUIDs (content
      commits here mean "a matched doc changed" → recompute against
      the current match list, no re-evaluation needed).
    * `subscribed_dirs` — every directory schema doc visited by the
      last `select/3` walk (commits here mean "the tree shape under a
      visited directory may have changed" → re-run `select/3`, diff
      against the previous sets, subscribe newly-matched docs /
      newly-visited dirs, unsubscribe ones that dropped out, then
      recompute).

  A commit lands in exactly one bucket (a UUID can't be both a
  directory schema AND a matched leaf doc in the same walk, since a
  walk visits directories to descend and records matches on the
  segment where the pattern is exhausted) — `handle_info/2` checks
  `subscribed_dirs` first, then `subscribed_docs`, then ignores.

  ## Compute function shape

  Exactly one of `:compute_fn` / `:code_uuid`, mirroring
  `ViewCompute`'s `init/1` validation:

    * `:compute_fn` — `(matches :: [%{path: String.t(), uuid: String.t()}],
      ctx :: map) -> new_target_content :: String.t()`. It receives the
      CURRENT match list only — reading matched docs' content is the
      compute's own job via `Commonplace.Black.json/2` /
      `Commonplace.Black.xml/2` (keeps this engine thin, per spec).
      `ctx` carries `%{root_uuid: _, pattern: _, store: _}`.
    * `:code_uuid` — an Elixir source-code doc compiled and run via
      `Commonplace.View.ComputeRunner`, exactly like `ViewCompute`'s
      M7 path — except unlike `ViewCompute`, this module does NOT
      subscribe to the code doc's own commits to trigger a restart.
      That reactivity axis (recompiling the compute's OWN definition)
      is a `ViewCompute`-specific refinement not asked for by spec §2;
      flagged in the CX-o1l9 build report as a scope note, not a
      silent omission.

  Writes go through the same `Commonplace.CommandRouter.write/3` call
  site `ViewCompute` uses — the write funnel's stable hand and the
  qat5.3 gate apply here for free, same as every other compute.

  ## Loop-safety (spec §2's "one obvious self-retrigger cycle")

  `init/1` refuses to start (returns `{:stop, reason}`) if `target_uuid`
  itself is a member of the INITIAL match set for `pattern` under
  `root_uuid` — that would make every write to the target immediately
  re-trigger this same server. Deeper cycle detection (e.g. a chain of
  two or more `PatternCompute`s feeding each other) is explicitly out
  of scope for M1, per spec.

  ## What this deliberately does NOT do (scope discipline)

  No rate fuse / backpressure timeout machinery like `ViewCompute`'s R6
  (spawn_monitor + fuse + coalesce). `ViewCompute`'s fuse defends
  against a REACTIVE LOOP; `PatternCompute`'s only self-loop vector is
  the target-matches-pattern case already refused at init, and deeper
  cycles are out of scope by spec. Recompute here runs inline
  (synchronously) in `handle_info/2`, wrapped in `try/rescue` so an
  author's `compute_fn` raising doesn't crash the GenServer — flagged
  in the build report as a deliberate simplification versus mirroring
  `ViewCompute`'s async/timeout/fuse trio exactly.
  """

  use GenServer
  require Logger

  alias Commonplace.Black
  alias Commonplace.CommandRouter
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.View.ComputeRunner

  @default_max_depth 32
  @default_limit 10_000

  defstruct [
    :root_uuid,
    :pattern,
    :target_uuid,
    :compute_fn,
    :code_uuid,
    :name,
    :router,
    :store,
    :max_depth,
    :limit,
    matches: [],
    subscribed_docs: MapSet.new(),
    subscribed_dirs: MapSet.new()
  ]

  @type match :: %{path: String.t(), uuid: String.t()}

  @type t :: %__MODULE__{
          root_uuid: String.t(),
          pattern: String.t(),
          target_uuid: String.t(),
          compute_fn: ([match()], map() -> String.t()),
          code_uuid: String.t() | nil,
          name: atom() | nil,
          router: GenServer.server(),
          store: GenServer.server(),
          max_depth: pos_integer(),
          limit: pos_integer(),
          matches: [match()],
          subscribed_docs: MapSet.t(),
          subscribed_dirs: MapSet.t()
        }

  # --- Client API ---

  @doc """
  Start a `PatternCompute` GenServer watching `pattern` under
  `root_uuid` and writing recomputed content to `target_uuid`.

  Required opts: `:root_uuid`, `:pattern`, `:target_uuid`, and exactly
  one of `:compute_fn` / `:code_uuid`.

  Optional opts: `:store` (default `CommitStoreClient`), `:router`
  (default `CommandRouter`), `:max_depth` (default
  #{@default_max_depth}), `:limit` (default #{@default_limit}),
  `:name`, `:spec_context` (passed to `ComputeRunner` when using
  `:code_uuid`).
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc """
  Force a synchronous recompute against the CURRENT match set (does
  not re-run `select/3`). Useful for tests / seeding.
  """
  def recompute(server) do
    GenServer.call(server, :recompute)
  end

  @doc "Force a synchronous re-evaluation of the match set, then recompute."
  def refresh(server) do
    GenServer.call(server, :refresh)
  end

  @doc "Get the current state (for tests and smoke checks)."
  def state(server) do
    GenServer.call(server, :state)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    pattern = Keyword.fetch!(opts, :pattern)
    target_uuid = Keyword.fetch!(opts, :target_uuid)
    name = Keyword.get(opts, :name)
    router = Keyword.get(opts, :router, CommandRouter)
    store = Keyword.get(opts, :store, CommitStoreClient)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    limit = Keyword.get(opts, :limit, @default_limit)

    compute_fn_opt = Keyword.get(opts, :compute_fn)
    code_uuid_opt = Keyword.get(opts, :code_uuid)

    with {:ok, {compute_fn, code_uuid}} <-
           resolve_compute(compute_fn_opt, code_uuid_opt, opts, store),
         {matches, dirs} <-
           Black.select(root_uuid, pattern,
             store: store,
             max_depth: max_depth,
             limit: limit,
             with_dirs: true
           ),
         :ok <- refuse_self_match(matches, target_uuid) do
      doc_uuids = MapSet.new(matches, & &1.uuid)
      Enum.each(doc_uuids, &CPPubSub.subscribe_blue/1)
      Enum.each(dirs, &CPPubSub.subscribe_blue/1)

      state = %__MODULE__{
        root_uuid: root_uuid,
        pattern: pattern,
        target_uuid: target_uuid,
        compute_fn: compute_fn,
        code_uuid: code_uuid,
        name: name,
        router: router,
        store: store,
        max_depth: max_depth,
        limit: limit,
        matches: matches,
        subscribed_docs: doc_uuids,
        subscribed_dirs: dirs
      }

      send(self(), :initial_compute)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp refuse_self_match(matches, target_uuid) do
    if Enum.any?(matches, &(&1.uuid == target_uuid)) do
      {:error,
       "target_uuid #{target_uuid} matches the watched pattern — would self-retrigger on every write"}
    else
      :ok
    end
  end

  defp resolve_compute(nil, nil, _opts, _store) do
    {:error, "must supply exactly one of :compute_fn or :code_uuid"}
  end

  defp resolve_compute(fn_opt, nil, _opts, _store) when is_function(fn_opt, 2) do
    {:ok, {fn_opt, nil}}
  end

  defp resolve_compute(nil, code_uuid, opts, store) when is_binary(code_uuid) do
    spec_context = Keyword.get(opts, :spec_context, %{})

    with :ok <- ComputeRunner.validate(code_uuid, store) do
      compute_fn = fn matches, ctx ->
        case ComputeRunner.compute(code_uuid, matches, Map.merge(spec_context, ctx), store) do
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
    do_compute(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:commit, uuid, _commit_id, _meta}, state) do
    cond do
      MapSet.member?(state.subscribed_dirs, uuid) ->
        {:noreply, reevaluate_and_compute(state)}

      MapSet.member?(state.subscribed_docs, uuid) ->
        do_compute(state)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:recompute, _from, state) do
    do_compute(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = reevaluate_and_compute(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # --- Private ---

  # Re-run select/3, diff the new match/dir sets against what we're
  # currently subscribed to, subscribe the deltas, unsubscribe dropped
  # entries, then recompute against the fresh match list. This is the
  # THE-pin machinery: a directory-schema commit is what calls this.
  defp reevaluate_and_compute(state) do
    {new_matches, new_dirs} =
      Black.select(state.root_uuid, state.pattern,
        store: state.store,
        max_depth: state.max_depth,
        limit: state.limit,
        with_dirs: true
      )

    new_doc_uuids = MapSet.new(new_matches, & &1.uuid)

    diff_subscriptions(state.subscribed_docs, new_doc_uuids)
    diff_subscriptions(state.subscribed_dirs, new_dirs)

    state = %{
      state
      | matches: new_matches,
        subscribed_docs: new_doc_uuids,
        subscribed_dirs: new_dirs
    }

    do_compute(state)
    state
  end

  defp diff_subscriptions(old_set, new_set) do
    added = MapSet.difference(new_set, old_set)
    removed = MapSet.difference(old_set, new_set)
    Enum.each(added, &CPPubSub.subscribe_blue/1)
    Enum.each(removed, &CPPubSub.unsubscribe_blue/1)
  end

  # Run compute_fn against the CURRENT match list and write the result
  # to target_uuid. Never lets a raising compute_fn crash this
  # GenServer (see moduledoc "What this deliberately does NOT do").
  defp do_compute(%__MODULE__{} = state) do
    try do
      ctx = %{root_uuid: state.root_uuid, pattern: state.pattern, store: state.store}
      new_content = state.compute_fn.(state.matches, ctx)

      case CommandRouter.write(state.router, state.target_uuid, new_content) do
        {:ok, _info} ->
          :ok

        {:error, :not_found} ->
          Logger.warning(
            "PatternCompute #{inspect(state.name)}: target #{state.target_uuid} not found — will not render until created"
          )

        {:error, reason} ->
          Logger.error("PatternCompute #{inspect(state.name)}: write failed: #{inspect(reason)}")
      end

      :ok
    rescue
      e ->
        Logger.error(
          "PatternCompute #{inspect(state.name)}: compute raised #{Exception.message(e)}"
        )

        :ok
    end
  end
end
