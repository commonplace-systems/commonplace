defmodule Commonplace.CLI.Event do
  @moduledoc "Read red event logs."

  alias Commonplace.CLI
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStoreClient, as: CommitStore

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)

    case args do
      [] ->
        list_event_logs(data_dir)

      ["list"] ->
        list_event_logs(data_dir)

      [uuid | rest] ->
        {opts, _} =
          OptionParser.parse(rest,
            strict: [last: :integer, json: :boolean],
            aliases: [n: :last]
          )

        read_event_log(uuid, opts)
    end
  end

  defp list_event_logs(data_dir) do
    status_file = Path.join(data_dir, "orchestrator_status.json")

    case File.read(status_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"processes" => processes}} ->
            Enum.each(processes, fn {name, info} ->
              IO.puts("#{name}")

              if info["sandbox_dir"] do
                IO.puts("  sandbox: #{info["sandbox_dir"]}")
              end

              if info["os_pid"] do
                IO.puts("  pid: #{info["os_pid"]}")
              end
            end)

          _ ->
            IO.puts(:stderr, "Could not parse orchestrator status.")
        end

      {:error, _} ->
        IO.puts(:stderr, "No orchestrator status found. Is 'commonplace serve' running?")
        System.halt(1)
    end
  end

  defp read_event_log(uuid, opts) do
    log = load_red_log(uuid)
    events = RedLog.read(log)

    events =
      if opts[:last] do
        Enum.take(events, -opts[:last])
      else
        events
      end

    if opts[:json] do
      IO.puts(Jason.encode!(events, pretty: true))
    else
      Enum.each(events, &format_event/1)
    end
  end

  # Load a RedLog via CommitStoreClient so it works with remote nodes.
  defp load_red_log(uuid) do
    RedLog.load(uuid, CommitStore)
  end

  defp format_event(%{"type" => type, "line" => line, "timestamp" => ts}) do
    # Compact timestamp: just time portion
    time =
      case String.split(ts, "T") do
        [_, time_part] -> String.replace(time_part, ~r/\.\d+Z$/, "")
        _ -> ts
      end

    prefix = if type == "stderr", do: "ERR", else: "   "
    IO.puts("[#{time}] #{prefix} #{line}")
  end

  defp format_event(%{"type" => type} = event) do
    IO.puts("[#{type}] #{inspect(Map.drop(event, ["type"]))}")
  end

  defp format_event(event) do
    IO.puts(inspect(event))
  end
end
