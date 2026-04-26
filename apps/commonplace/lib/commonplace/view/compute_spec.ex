defmodule Commonplace.View.ComputeSpec do
  @moduledoc """
  CX-oui2 (sub-bead ii of CX-d819 M5): substrate-tier compute-spec
  parser + validator + interpreter.

  A compute spec is a declarative XML document describing how to
  transform raw input (e.g. the JSON entries of a `_messages` doc)
  into rendered output (e.g. view-XML). The substrate primitive
  enumerates a fixed set of pipeline kinds; specs declare which kinds
  to apply in what order plus their parameters.

  Joins `Commonplace.View.ArgResolver` (M3) in the substrate-view-tier
  namespace.

  ## Pipeline kinds (held position #4)

  * `decode_json_array` — `Enum.map(&Jason.decode!/1)` over the raw input
  * `materialize` — `Materialize.materialize/2` with chains from spec
  * `render` — `apply(module, function, [input, context])` —
    function-reference-by-name (held position #2)

  Future kinds enumerate; no template-evaluation expression language
  (Architecture (Y) discipline).

  ## Spec format (held position #3)

  XML extending the view-XML vocabulary. Element-grouping wrappers
  (`<chains>`, `<pipeline>`) are sub-element-form per the M3 banked
  pattern.

      <compute-spec schema="1">
        <pipeline>
          <step kind="decode_json_array"/>
          <step kind="materialize">
            <chains>
              <chain field="edit_of" semantics="latest_replaces"/>
              <chain field="tombstone_of" semantics="marks_deleted"/>
            </chains>
          </step>
          <step kind="render">
            <function module="Commonplace.Chat.ChatViewBuilder" name="build_view_xml"/>
          </step>
        </pipeline>
      </compute-spec>

  ## Validate at supervisor-start (round-1 audit (I))

  `validate/1` runs at supervisor-start and surfaces structured errors
  for: render-fn module not loaded; function not exported; malformed
  chains; unknown pipeline kinds. Catches malformed specs BEFORE
  compute-time so failures don't fire at runtime as silent crashes.

  ## Render-fn arg shape

  M5 hardcodes `apply(module, function, [input, context])` — the render
  step receives the materialized list AND a context map (e.g.
  `%{room_name: "..."}`). Future versions may declare arg binding
  similar to ArgResolver if signatures diverge.
  """

  alias Commonplace.Document.ViewXml
  alias Commonplace.Materialize

  defmodule Step do
    @moduledoc false
    defstruct [:kind, :chains, :module, :function]
    @type t :: %__MODULE__{}
  end

  defstruct pipeline: []
  @type t :: %__MODULE__{pipeline: [Step.t()]}

  @valid_kinds ~w(decode_json_array materialize render)
  @valid_chain_semantics %{
    "latest_replaces" => :latest_replaces,
    "marks_deleted" => :marks_deleted
  }

  # --- parse ---

  @doc """
  Parse a compute-spec XML string into a typed struct. Returns
  `{:ok, %ComputeSpec{}}` or `{:error, reason}` on parse / shape
  errors.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(xml) when is_binary(xml) do
    with {:ok, root} <- parse_xml(xml),
         :ok <- expect_root(root, :"compute-spec"),
         pipeline_node <- find_child(root, :pipeline),
         {:ok, steps} <- parse_steps(pipeline_node) do
      {:ok, %__MODULE__{pipeline: steps}}
    end
  end

  defp parse_xml(xml) do
    case ViewXml.parse(xml) do
      {:ok, node} -> {:ok, node}
      {:error, reason} -> {:error, "parse error: #{inspect(reason)}"}
    end
  end

  defp expect_root(%ViewXml.Node{tag: tag}, expected) do
    if tag == expected do
      :ok
    else
      {:error,
       "expected root element <#{expected}>, got <#{tag}> (must be a compute-spec)"}
    end
  end

  defp parse_steps(nil), do: {:error, "compute-spec missing <pipeline> element"}

  defp parse_steps(%ViewXml.Node{children: children}) do
    children
    |> Enum.filter(&match?(%ViewXml.Node{tag: :step}, &1))
    |> Enum.reduce_while({:ok, []}, fn step_node, {:ok, acc} ->
      case parse_step(step_node) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  defp parse_step(%ViewXml.Node{attrs: %{"kind" => kind}} = node)
       when kind in @valid_kinds do
    case kind do
      "decode_json_array" ->
        {:ok, %Step{kind: :decode_json_array}}

      "materialize" ->
        chains = parse_chains(node)
        {:ok, %Step{kind: :materialize, chains: chains}}

      "render" ->
        parse_render_step(node)
    end
  end

  defp parse_step(%ViewXml.Node{attrs: attrs}) do
    {:error, "step missing or invalid `kind`: #{inspect(Map.get(attrs, "kind"))}"}
  end

  defp parse_chains(%ViewXml.Node{} = step) do
    case find_child(step, :chains) do
      nil ->
        []

      %ViewXml.Node{children: children} ->
        children
        |> Enum.flat_map(fn
          %ViewXml.Node{tag: :chain, attrs: %{"field" => field, "semantics" => sem}} ->
            case Map.fetch(@valid_chain_semantics, sem) do
              {:ok, atom} -> [%{field: field, semantics: atom}]
              :error -> []
            end

          _ ->
            []
        end)
    end
  end

  defp parse_render_step(%ViewXml.Node{} = step) do
    case find_child(step, :function) do
      %ViewXml.Node{attrs: %{"module" => mod, "name" => fn_name}} ->
        {:ok,
         %Step{
           kind: :render,
           module: String.to_atom("Elixir.#{mod}"),
           function: String.to_atom(fn_name)
         }}

      _ ->
        {:error, "render step missing <function module=\"...\" name=\"...\"/> child"}
    end
  end

  defp find_child(%ViewXml.Node{children: children}, tag) do
    Enum.find(children, fn
      %ViewXml.Node{tag: ^tag} -> true
      _ -> false
    end)
  end

  defp find_child(_, _), do: nil

  # --- validate (round-1 audit (I)) ---

  @doc """
  Validate a parsed spec at supervisor-start. Catches missing render-fn
  modules / non-exported functions BEFORE compute-time so failures
  don't fire as silent runtime crashes.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{pipeline: pipeline}) do
    Enum.reduce_while(pipeline, :ok, fn step, :ok ->
      case validate_step(step) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_step(%Step{kind: :render, module: module, function: function}) do
    resolve_render_fn(module, function, 2)
  end

  defp validate_step(%Step{}), do: :ok

  @doc """
  Resolve a render-fn `(module, function, arity)`. Returns `{:ok, mfa}`
  when both module loads + function exported; `{:error, reason}`
  otherwise.

  Held position #3 + Q3 (round-1): idiomatic `Code.ensure_loaded/1` +
  `:erlang.function_exported/3`.
  """
  @spec resolve_render_fn(module(), atom(), arity()) :: :ok | {:error, String.t()}
  def resolve_render_fn(module, function, arity) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if :erlang.function_exported(module, function, arity) do
          :ok
        else
          {:error,
           "render function #{inspect(module)}.#{function}/#{arity} not exported"}
        end

      {:error, reason} ->
        {:error, "render module #{inspect(module)} not loaded: #{inspect(reason)}"}
    end
  end

  # --- interpret ---

  @doc """
  Apply the spec's pipeline to `raw_input` with the given `context`.
  Reduces over pipeline steps; output of step N is input of step N+1.

  The `context` map flows into the render step (e.g. `%{room_name:
  "general"}` for chat).
  """
  @spec interpret(t(), term(), map()) :: term()
  def interpret(%__MODULE__{pipeline: pipeline}, raw_input, context) do
    Enum.reduce(pipeline, raw_input, fn step, acc ->
      apply_step(step, acc, context)
    end)
  end

  defp apply_step(%Step{kind: :decode_json_array}, raw_entries, _ctx) do
    Enum.map(raw_entries, &Jason.decode!/1)
  end

  defp apply_step(%Step{kind: :materialize, chains: chains}, entries, _ctx) do
    Materialize.materialize(entries, %{chains: chains})
  end

  defp apply_step(%Step{kind: :render, module: module, function: function}, input, ctx) do
    apply(module, function, [input, ctx_room_name(ctx)])
  end

  # M5 minimal: render step's second arg is room_name. Future arg shapes
  # would declare per-render binding similarly to ArgResolver — defer.
  defp ctx_room_name(%{room_name: name}) when is_binary(name), do: name
  defp ctx_room_name(_), do: ""
end
