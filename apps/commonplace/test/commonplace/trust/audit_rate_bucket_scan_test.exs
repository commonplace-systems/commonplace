defmodule Commonplace.Trust.AuditRateBucketScanTest do
  @moduledoc """
  The flood-guard rate table is global shared mutable state: one named
  ETS table for the whole BEAM run, ticked by every denial in the suite
  because the handler attaches at application boot. A test that attaches
  the audit handler and asserts on dispatcher offers therefore inherits
  whatever ran before it — unless it starts from a fresh bucket.

  Four files knew this and one did not, and the one that did not was a
  red CI on the first post-merge run (the choke perf test's non-vacuity
  guard fired on a bucket a neighbor had saturated). This scan makes the
  requirement structural: it lives here, once, instead of in the setup
  discipline of N files.
  """
  use ExUnit.Case, async: true

  test "every test file that attaches the audit handler resets the rate bucket" do
    trust_test_dir = __DIR__

    files =
      Path.wildcard(Path.join([trust_test_dir, "..", "..", "**", "*_test.exs"]))
      |> Enum.map(&Path.expand/1)
      |> Enum.reject(&(&1 == Path.expand(__ENV__.file)))

    attaching =
      Enum.filter(files, fn f -> File.read!(f) =~ "AuditLog.attach(" end)

    # Denominator floor: if the glob breaks, this scan must go red, not
    # quietly scan nothing. Five attaching files existed when written.
    assert length(attaching) >= 5,
           "scan found only #{length(attaching)} attaching test files — glob or layout broke"

    offenders =
      Enum.reject(attaching, fn f -> File.read!(f) =~ "reset_rate_table" end)

    assert offenders == [],
           "these test files attach the audit handler without resetting the shared " <>
             "flood-guard bucket (see moduledoc for why that is a CI flake): " <>
             inspect(Enum.map(offenders, &Path.relative_to_cwd/1))
  end
end
