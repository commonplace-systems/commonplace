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

      systemd-run --user --unit=cp-ah-backfill \\
        -p MemoryMax=6G -p OOMScoreAdjust=900 \\
        mix commonplace.backfill_accepted_heads \\
          --data-dir /home/jes/commonplace/workspace/.commonplace \\
          --unit cp-ah-backfill --expected-bytes 6442450944

  ⚠️ `--data-dir` is the PARENT of the store, NOT the store itself:
  `CommitStore.init/1` does `Path.join(data_dir, "commits")`, so pass
  `.../.commonplace` and it opens `.../.commonplace/commits`. Passing
  `.../.commonplace/commits` opens `.../.commonplace/commits/commits`, a
  BRAND-NEW EMPTY store created on the spot — which the vacuity gate below
  now refuses (commonplace-coder #13593: a run that "succeeded" on a store
  that did not exist). `-p OOMScoreAdjust=900` is REQUIRED (boss #13622): a
  bare systemd-run unit inherits adj 200 = tied with hermes's live BEAM.

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

  # Below this, a store is empty-or-newly-created rather than the real
  # 6G corpus. The vacuity gate refuses to open it (commonplace-coder
  # #13593 / boss #13630): a wrong --data-dir CREATES an empty store on
  # open and the backfill "succeeds" on nothing. Override with
  # --min-store-bytes for a legitimately small store (tests, a fresh dev
  # workspace). 1 MB is far below any real corpus and far above an empty
  # CubDB's a-few-KB header files.
  @min_store_bytes 1_000_000

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          data_dir: :string,
          unit: :string,
          expected_bytes: :integer,
          chunk: :integer,
          min_store_bytes: :integer
        ]
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

    # ⛔ NON-VACUITY GATE (commonplace-coder #13593, boss #13630): refuse
    # BEFORE start_link, so we never create the empty store we are guarding
    # against. See check_non_vacuous/2.
    min_bytes = opts[:min_store_bytes] || @min_store_bytes

    case check_non_vacuous(data_dir, min_bytes) do
      {:ok, store_dir, cub_bytes} ->
        Logger.info("§3 non-vacuity gate PASSED: #{store_dir} holds #{cub_bytes} bytes of .cub")

      {:error, {:no_store, store_dir}} ->
        Mix.raise(
          "no store at #{store_dir}: CommitStore appends /commits to --data-dir, so pass the " <>
            "PARENT (e.g. .../.commonplace, not .../.commonplace/commits). Refusing to " <>
            "CREATE-on-open and 'succeed' on a store that never existed."
        )

      {:error, {:vacuous, store_dir, cub_bytes, min}} ->
        Mix.raise(
          "store at #{store_dir} holds only #{cub_bytes} bytes of .cub (< #{min}): empty, or a " <>
            "wrong-path store created on open. Refusing a vacuous run (a backfill that 'succeeds' " <>
            "on nothing). If this store is legitimately small, pass --min-store-bytes."
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

  @doc """
  Non-vacuity gate (commonplace-coder #13593, boss #13630). The store must
  EXIST and be non-empty BEFORE CommitStore opens it.

  `CommitStore.init/1` does `Path.join(data_dir, "commits")` and CREATES the
  dir on open — so a wrong `--data-dir` (e.g. `.../commits`, which opens
  `.../commits/commits`) yields a fresh empty store and a backfill that
  reports `{:ready, n}` off a corpus that never existed. This checks the
  exact dir CommitStore will open, WITHOUT creating it: `{:error,
  {:no_store, dir}}` if the dir is absent (wrong --data-dir), `{:error,
  {:vacuous, dir, bytes, min}}` if it holds less than `min_bytes` of `.cub`
  (empty or newly-created), `{:ok, dir, bytes}` otherwise. Public for
  testing: the three arms are this gate's red-first demonstration —
  "the work was done" must not share a report shape with "there was nothing
  to open".
  """
  @spec check_non_vacuous(String.t(), non_neg_integer()) ::
          {:ok, String.t(), non_neg_integer()}
          | {:error, {:no_store, String.t()}}
          | {:error, {:vacuous, String.t(), non_neg_integer(), non_neg_integer()}}
  def check_non_vacuous(data_dir, min_bytes) do
    store_dir = Path.join(data_dir, "commits")

    cond do
      not File.dir?(store_dir) ->
        {:error, {:no_store, store_dir}}

      true ->
        cub_bytes =
          store_dir
          |> Path.join("*.cub")
          |> Path.wildcard()
          |> Enum.map(&File.stat!(&1).size)
          |> Enum.sum()

        if cub_bytes < min_bytes do
          {:error, {:vacuous, store_dir, cub_bytes, min_bytes}}
        else
          {:ok, store_dir, cub_bytes}
        end
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
