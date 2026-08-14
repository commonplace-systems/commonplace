defmodule Commonplace.DeployGapMonitor do
  @moduledoc """
  Periodically makes a serve-side deploy gap visible in the serve log.

  A Phoenix-as-serve node runs with interactive code loading and does not
  compile after it starts. Its process start is therefore the correct
  reference: a beam newer than that start is code this serve was not built
  with, and lazily loading it would be an unplanned partial deploy.

  `bin/cp-deploy-gap` owns the measurement and names every newer beam. This
  process only supplies the missing push behaviour: successful empty checks
  are silent, while a non-empty result is logged without an operator having
  to remember to invoke the gauge.

  This is an alarm, not a deployment policy. It neither restarts the serve nor
  prevents the runtime from loading a newer beam.
  """

  use GenServer

  require Logger

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def check(opts \\ []) do
    command = Keyword.get(opts, :command, default_command())
    args = Keyword.get(opts, :args, ["--assert-empty"])
    command_opts = Keyword.get(opts, :command_opts, default_command_opts(command))

    try do
      case System.cmd(command, args, command_opts) do
        {_output, 0} ->
          :quiet

        {output, 1} ->
          {:gap, output}

        {output, status} ->
          {:error, status, output}
      end
    rescue
      error in ErlangError -> {:error, :exec, Exception.message(error)}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      check_opts: Keyword.take(opts, [:command, :args, :command_opts])
    }

    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    report(check(state.check_opts))
    Process.send_after(self(), :check, state.interval_ms)
    {:noreply, state}
  end

  @doc false
  def report(:quiet), do: :ok

  def report({:gap, output}) do
    Logger.error("""
    DEPLOY GAP DETECTED — this serve may lazily load code built after it started.
    #{String.trim_trailing(output)}
    """)
  end

  def report({:error, status, output}) do
    Logger.error("""
    DEPLOY GAP MONITOR FAILED — the serve's deploy gap is unknown (gauge exit #{status}).
    #{String.trim_trailing(output)}
    """)
  end

  defp default_command do
    Path.expand("bin/cp-deploy-gap")
  end

  defp default_command_opts(command) do
    [cd: Path.dirname(Path.dirname(command)), stderr_to_stdout: true]
  end
end
