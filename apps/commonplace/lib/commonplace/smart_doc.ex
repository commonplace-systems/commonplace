defmodule Commonplace.SmartDoc do
  @moduledoc """
  Macro for declaring reactive dataflow ports on smart documents.

  ## Usage

      defmodule MyWatcher do
        use Commonplace.SmartDoc

        @blue_inputs ["config"]
        @cyan_outputs ["output"]
        @red_inputs ["events"]
        @magenta_outputs ["alerts"]

        def handle_blue("config", doc) do
          # react to config changes
        end

        def handle_red("events", event) do
          # react to events
        end
      end

  ## Port Types

  - `@blue_inputs` — subscribe to docs' commit streams
  - `@cyan_outputs` — push edits to docs (implicitly subscribes to their blue)
  - `@red_inputs` — subscribe to docs' event logs
  - `@magenta_outputs` — docs to push events to (optional declaration)

  ## Declaring ports vs driving them

  The macro half (above) only *declares* ports and input handlers: it
  generates `__ports__/0` (the four lists as a map, read by the
  Orchestrator) plus default no-op `handle_blue/2` / `handle_red/2` that
  you override to react to incoming blue commits and red events.

  The output half is the runtime helpers `push_cyan/3` and
  `push_magenta/3`. Ports are declared by a logical *ref* (e.g.
  `"output"`); the Orchestrator resolves each ref to a doc UUID at
  wiring time and hands it back in `state.resolved_ports`. The push
  helpers look the ref up there, so an unresolved ref no-ops to
  `:error`. `push_cyan/3` routes through
  `Commonplace.CommandRouter.write/3` → `Commonplace.Document.Diff`
  (Myers grapheme diff → minimal insert/delete ops) — the same write
  path MCP uses, so computed edits get the same CRDT-correctness as
  authored ones.
  """

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :blue_inputs, accumulate: false)
      Module.register_attribute(__MODULE__, :cyan_outputs, accumulate: false)
      Module.register_attribute(__MODULE__, :red_inputs, accumulate: false)
      Module.register_attribute(__MODULE__, :magenta_outputs, accumulate: false)

      @before_compile Commonplace.SmartDoc
    end
  end

  defmacro __before_compile__(env) do
    blue = Module.get_attribute(env.module, :blue_inputs) || []
    cyan = Module.get_attribute(env.module, :cyan_outputs) || []
    red = Module.get_attribute(env.module, :red_inputs) || []
    magenta = Module.get_attribute(env.module, :magenta_outputs) || []

    quote do
      def __ports__ do
        %{
          blue_inputs: unquote(blue),
          cyan_outputs: unquote(cyan),
          red_inputs: unquote(red),
          magenta_outputs: unquote(magenta)
        }
      end

      def handle_blue(_ref, _doc), do: :ok
      def handle_red(_ref, _event), do: :ok

      defoverridable handle_blue: 2, handle_red: 2
    end
  end

  # --- Runtime Helpers ---

  alias Commonplace.CommandRouter
  alias Commonplace.Dataflow.Magenta

  @doc """
  Push a cyan (CRDT write) to a resolved port.

  The `state` map must contain:
  - `:resolved_ports` — the ref-to-UUID map from Orchestrator wiring

  Delegates to `Commonplace.CommandRouter.write/3`, which uses
  `Commonplace.Document.Diff.apply_diff/3` (Myers-diff on graphemes) to
  produce minimal insert/delete ops against the current doc state.
  This preserves concurrent edits and is the same call site MCP `write`
  uses, so both authored and computed edits share the same CRDT-correctness
  guarantees (see docs/views.md "View computation" and
  Commonplace.Document.Diff contract).

  Returns `:ok` or `:error` if the docref is unresolved or the write
  fails.
  """
  def push_cyan(state, docref, content) do
    uuid = Map.get(state.resolved_ports || %{}, docref)

    if uuid do
      case CommandRouter.write(uuid, content) do
        {:ok, _info} -> :ok
        {:error, _reason} -> :error
      end
    else
      :error
    end
  end

  @doc """
  Push a magenta (ephemeral event) to a resolved port.

  The `state` map must contain:
  - `:resolved_ports` — the ref-to-UUID map from Orchestrator wiring

  The `event` should be a `Commonplace.Dataflow.Magenta` struct or a map
  with `:type`, `:source`, and `:payload` keys.

  Returns `:ok` or `:error` if the docref is unresolved.
  """
  def push_magenta(state, docref, event) do
    uuid = Map.get(state.resolved_ports || %{}, docref)

    if uuid do
      msg =
        case event do
          %Magenta{} ->
            event

          %{type: type, source: source} ->
            Magenta.message(type, source, Map.get(event, :payload, %{}))

          %{} ->
            Magenta.message("event", docref, event)
        end

      Magenta.send(uuid, msg)
      :ok
    else
      :error
    end
  end
end
