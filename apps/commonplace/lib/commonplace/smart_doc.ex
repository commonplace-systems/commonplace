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
end
