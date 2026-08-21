defmodule Mix.Tasks.Commonplace.TaskCompileRequirementsTest do
  @moduledoc """
  Every custom mix task in this app MUST declare `@requirements ["compile"]`.

  Without it, `mix <task>` executes whatever beams `_build` already holds —
  Mix does not recompile before a custom task of this shape. Demonstrated
  live 2026-08-21 (boss #14448): pass 3 of the (a) migration ran a
  41-minute-stale `DocCommitBackfill.beam` and re-died on a bug the working
  tree had already fixed; a touch-probe confirmed the mechanism (source
  touched, task run, beam mtime unchanged). Host-gated ceremonies verify
  ceilings, kill-order, and store non-vacuity — this gate closes the one
  precondition none of that covers: that the code that runs is the code
  that was merged.
  """
  use ExUnit.Case, async: true

  @tasks_glob Path.join([__DIR__, "..", "..", "..", "lib", "mix", "tasks", "*.ex"])

  test "every mix task declares @requirements [\"compile\"] — and the corpus is non-empty" do
    files = @tasks_glob |> Path.expand() |> Path.wildcard()

    # Corpus control: a wrong glob returns [] and would green vacuously.
    assert length(files) >= 5,
           "expected at least the 5 known task files, found #{inspect(files)} — " <>
             "an empty corpus is a broken glob, not a clean sweep"

    missing =
      Enum.reject(files, fn file ->
        File.read!(file) =~ ~s(@requirements ["compile"])
      end)

    assert missing == [],
           "mix task(s) without @requirements [\"compile\"] — these will run STALE " <>
             "beams when invoked after a merge without an explicit compile: " <>
             inspect(Enum.map(missing, &Path.basename/1))
  end
end
