defmodule Commonplace.CLI.Signal do
  @moduledoc "Send a magenta message to a topic."

  alias Commonplace.CLI
  alias Commonplace.Dataflow.Magenta

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)

    case args do
      [topic, type | rest] ->
        payload =
          case rest do
            [json | _] ->
              case Jason.decode(json) do
                {:ok, map} when is_map(map) -> map
                _ -> %{"value" => json}
              end

            [] ->
              %{}
          end

        msg = Magenta.message(type, "cli", payload)
        Magenta.send(topic, msg)
        IO.puts("Sent #{type} to #{topic}")

      [_topic] ->
        IO.puts(:stderr, "Usage: commonplace signal <topic> <type> [payload_json]")
        System.halt(1)

      [] ->
        IO.puts(:stderr, "Usage: commonplace signal <topic> <type> [payload_json]")
        System.halt(1)
    end
  end
end
