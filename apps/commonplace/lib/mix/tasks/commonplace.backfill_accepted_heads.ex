defmodule Mix.Tasks.Commonplace.BackfillAcceptedHeads do
  use Mix.Task

  @shortdoc "BUILD-1 §3: backfill the accepted-head index (run model (b), against a STOPPED serve)"

  @moduledoc """
  Backfills the accepted-head index for legacy documents. Run model (b),
  per `/home/jes/boss-clod/INCREMENT-3-BRIEF.md`: this is a SEPARATE process
  that opens the STOPPED serve's `data_dir` as the sole flock holder — NOT
  an erpc into the live serve. It must be launched under
  `systemd-run --user --unit=<name> -p MemoryMax=6G` so the ceiling
  actually bounds it and a kill hits this unit, never the (down) live serve.

      systemd-run --user --unit=cp-ah-backfill -p MemoryMax=6G \\
        mix commonplace.backfill_accepted_heads \\
          --data-dir /home/jes/commonplace/workspace/.commonplace/commits \\
          --unit cp-ah-backfill --expected-bytes 6442450944

  ## ① ceiling self-check, WHILE ACTIVE, LOGGED (paravel #13573 / boss #13577)

  systemd garbage-collects the transient unit on exit, so a unit that
  SUCCEEDED is byte-identical to a name that NEVER EXISTED
  (`MemoryMax=infinity, LoadState=not-found`). The check therefore cannot be
  done after the fact — but this task RUNS INSIDE its own unit, so the unit
  is active by construction, and it writes the verified triple (MemoryMax +
  LoadState + ActiveState) into its own log so the evidence outlives the
  unit. It REFUSES to run without `--unit` and a passing verification: a run
  without an enforced ceiling is not a run (①).

  ⚠️ The literal `6442450944` is 6G on this host's systemd; the durable
  instruction is the METHOD (verify LoadState=loaded and a finite MemoryMax;
  assert the exact value the launcher set via `--expected-bytes`). On
  another host, confirm the value from the probe pair (see the brief).

  Options:
    * `--data-dir PATH` (required) — the stopped serve's commits data_dir
    * `--unit NAME` (required) — this task's own systemd unit, to verify ①
    * `--expected-bytes N` — assert `MemoryMax == N` exactly (e.g. 6442450944)
    * `--chunk N` — docs per chunk (default: the module's 1000)
  """

  alias Commonplace.Store.{AcceptedHeadsBackfill, CommitStore}
  require Logger

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [data_dir: :string, unit: :string, expected_bytes: :integer, chunk: :integer]
      )

    data_dir =
      opts[:data_dir] ||
        Mix.raise("--data-dir is required (the STOPPED serve's commits data_dir)")

    unit =
      opts[:unit] ||
        Mix.raise("--unit is required: a run without a verified enforced ceiling is refused (①)")

    {:ok, _} = Application.ensure_all_started(:telemetry)

    # ① — verify the ceiling from our own unit, while active, and LOG the triple.
    triple_output = systemctl_triple(unit)
    Logger.info("§3 ① ceiling triple (unit=#{unit}): #{String.trim(triple_output)}")

    case verify_ceiling(triple_output, opts[:expected_bytes]) do
      {:ok, triple} ->
        Logger.info("§3 ① ceiling VERIFIED: #{inspect(triple)}")

      {:error, reason} ->
        Mix.raise(
          "§3 ① ceiling verification FAILED: #{inspect(reason)} — refusing to run " <>
            "without an enforced MemoryMax (a run without a ceiling is not a run)"
        )
    end

    name = :accepted_heads_backfill_store
    {:ok, _pid} = CommitStore.start_link(data_dir: data_dir, name: name)

    run_opts = if opts[:chunk], do: [chunk: opts[:chunk]], else: []
    report = AcceptedHeadsBackfill.run(name, run_opts)
    Logger.info("§3 backfill report: #{inspect(report)}")
    :ok
  end

  @doc """
  Verify the systemd unit's ceiling triple. `{:ok, triple}` only when the
  unit is `loaded` AND `MemoryMax` is finite (a ceiling is set) AND — when
  `expected_bytes` is given — matches it exactly. Public for testing: the
  three arms (loaded+finite, not-found, infinity) are ①'s red-first
  demonstration as a unit test.
  """
  @spec verify_ceiling(String.t(), integer() | nil) :: {:ok, map()} | {:error, term()}
  def verify_ceiling(systemctl_output, expected_bytes) do
    triple = parse_triple(systemctl_output)

    cond do
      triple.load_state != "loaded" ->
        {:error, {:unit_not_loaded, triple}}

      triple.memory_max in [nil, "", "infinity"] ->
        {:error, {:no_ceiling, triple}}

      expected_bytes != nil and triple.memory_max != Integer.to_string(expected_bytes) ->
        {:error, {:wrong_ceiling, triple, expected_bytes}}

      true ->
        {:ok, triple}
    end
  end

  @doc "Parse `systemctl show -p X` output into the MemoryMax/LoadState/ActiveState triple."
  @spec parse_triple(String.t()) :: %{
          memory_max: term(),
          load_state: term(),
          active_state: term()
        }
  def parse_triple(output) do
    map =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)

    %{
      memory_max: map["MemoryMax"],
      load_state: map["LoadState"],
      active_state: map["ActiveState"]
    }
  end

  defp systemctl_triple(unit) do
    {out, _status} =
      System.cmd(
        "systemctl",
        ["--user", "show", unit, "-p", "MemoryMax", "-p", "LoadState", "-p", "ActiveState"],
        stderr_to_stdout: true
      )

    out
  end
end
