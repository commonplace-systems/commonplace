defmodule Commonplace.Trust.DenySiteScanTest do
  @moduledoc """
  CX-t3xv acceptance criterion 6: **an injected unaudited deny site
  turns the scan red.** Deny → audit is structural inheritance, not
  per-site memory.

  The six-sites lesson, applied before rather than after: an
  enumeration maintained by remembering to maintain it is correct on
  the day it is written. This test reads the SOURCE TREE, finds every
  denial-class telemetry event actually present in it, and fails unless
  each is either audited (`AuditLog.events/0`) or exempt with a stated
  reason (`DenySites.exempt/0`).

  Adding a deny site and forgetting the audit wiring turns this red.
  That is the whole mechanism. The red-proof at the bottom injects
  exactly such a site into a throwaway tree and asserts the scanner
  reports it — because a scan that has never been observed going red is
  a scan nobody has shown can fail.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Trust.{AuditLog, DenySites}

  @umbrella Path.expand("../../../../..", __DIR__)

  # ── the scanner ──────────────────────────────────────────────────────

  @doc false
  def scan(root) do
    root
    |> source_files()
    |> Enum.flat_map(&events_in_file/1)
    |> Enum.uniq()
    |> Enum.filter(&DenySites.denial_class?/1)
  end

  defp source_files(root) do
    Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex"))
  end

  # Matches a literal telemetry event list. Deliberately literal-only:
  # a computed event name cannot be classified statically, and pretending
  # otherwise would put a false green in a scan whose whole value is that
  # it can go red.
  @event_re ~r/:telemetry\.execute\(\s*(\[[^\]]*\])/s

  defp events_in_file(path) do
    source = File.read!(path)

    @event_re
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [list] -> parse_event_list(list) end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_event_list(list) do
    segments =
      list
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # Every segment must be a literal atom; otherwise this is a computed
    # event name and the scanner declines to guess.
    if segments != [] and Enum.all?(segments, &String.match?(&1, ~r/^:[a-z_][a-zA-Z0-9_]*$/)) do
      Enum.map(segments, fn ":" <> name -> String.to_atom(name) end)
    end
  end

  # ── the registry must not lie about itself ───────────────────────────

  test "the audited registry and the handler's subscription are the SAME set" do
    registry = MapSet.new(Enum.map(DenySites.audited(), & &1.event))
    handler = MapSet.new(AuditLog.events())

    assert registry == handler,
           "DenySites.audited/0 claims coverage the handler does not subscribe to " <>
             "(or vice versa) — a registry that can disagree with reality is a check " <>
             "that cannot fail.\n" <>
             "  only in registry: #{inspect(MapSet.difference(registry, handler) |> MapSet.to_list())}\n" <>
             "  only in handler:  #{inspect(MapSet.difference(handler, registry) |> MapSet.to_list())}"

    assert DenySites.audited_matches_handler?()
  end

  test "every registry entry carries a stated reason" do
    for site <- DenySites.audited() ++ DenySites.exempt() ++ DenySites.unwired() do
      assert is_binary(site.reason) and String.length(site.reason) > 20,
             "registry entry #{inspect(site.event || site.where)} has no real reason — " <>
               "'why is this not audited' is the only question a reader of an exempt list has"

      assert is_binary(site.where) and site.where != ""
      assert is_binary(site.gate) and site.gate != ""
    end
  end

  # ── AC6 proper ───────────────────────────────────────────────────────

  test "every denial-class telemetry event in the tree is audited or explicitly exempt" do
    found = scan(@umbrella)
    accounted = DenySites.accounted_events()

    unaccounted = Enum.reject(found, &MapSet.member?(accounted, &1))

    # Never a bare count: report the per-hit shapes.
    assert unaccounted == [],
           """
           Unaudited deny site(s) found in the source tree.

           A telemetry event that names a refusal must either be handled by
           Commonplace.Trust.AuditLog (add it to @events AND to
           DenySites.audited/0) or be listed in DenySites.exempt/0 with the
           reason it is not a security audit record.

           unaccounted: #{inspect(unaccounted, pretty: true)}
           scanned: #{length(found)} denial-class events
           """

    # The scan must not be vacuous. A scanner that finds nothing reports
    # the same clean line whether the tree is clean or the regex is
    # broken — the silent-empty class.
    assert length(found) >= 8,
           "the scanner found only #{length(found)} denial-class events (#{inspect(found)}); " <>
             "that is implausibly few — suspect the scanner, not the tree"
  end

  test "the scan actually SEES the known deny sites (not a vacuous pass)" do
    found = MapSet.new(scan(@umbrella))

    for expected <- [
          [:commonplace, :commit, :rejected, :local_trust],
          [:commonplace, :commit, :rejected, :trust],
          [:commonplace, :code, :rejected, :trust],
          [:commonplace, :process, :rejected, :trust],
          [:commonplace, :federation, :rejected, :auth],
          [:commonplace, :trust, :read, :would_refuse],
          [:commonplace, :trust, :revocation, :ignored]
        ] do
      assert MapSet.member?(found, expected),
             "the scanner did not find #{inspect(expected)} — it is not reading the tree it " <>
               "claims to read"
    end
  end

  # ── the RED PROOF: inject an unaudited deny site ─────────────────────

  test "RED PROOF: an injected unaudited deny site turns the scan red" do
    root = Path.join(System.tmp_dir!(), "cp_deny_scan_#{:rand.uniform(1_000_000_000)}")
    lib = Path.join(root, "apps/fake_app/lib/fake")
    File.mkdir_p!(lib)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(lib, "new_gate.ex"), """
    defmodule Fake.NewGate do
      def refuse(thing) do
        :telemetry.execute(
          [:commonplace, :brand_new_gate, :rejected, :because_reasons],
          %{system_time: System.system_time()},
          %{thing: thing}
        )

        {:error, :denied}
      end
    end
    """)

    found = scan(root)

    assert [:commonplace, :brand_new_gate, :rejected, :because_reasons] in found,
           "the scanner did not detect the injected deny site: #{inspect(found)}"

    unaccounted = Enum.reject(found, &MapSet.member?(DenySites.accounted_events(), &1))

    assert unaccounted == [[:commonplace, :brand_new_gate, :rejected, :because_reasons]],
           "the injected site must be reported as UNACCOUNTED (this is the red the real " <>
             "test would show): #{inspect(unaccounted)}"
  end

  test "RED PROOF: a deny site whose name does not say 'rejected' is still caught" do
    root = Path.join(System.tmp_dir!(), "cp_deny_scan_out_#{:rand.uniform(1_000_000_000)}")
    lib = Path.join(root, "apps/fake_app/lib/fake")
    File.mkdir_p!(lib)
    on_exit(fn -> File.rm_rf!(root) end)

    # The syntactic-outlier lesson: the real tree's read gate says
    # "would_refuse" and its revocation site says "ignored".
    File.write!(Path.join(lib, "outlier.ex"), """
    defmodule Fake.Outlier do
      def check do
        :telemetry.execute([:commonplace, :thing, :would_refuse], %{}, %{})
        :telemetry.execute([:commonplace, :other, :denied], %{}, %{})
      end
    end
    """)

    found = scan(root)

    assert [:commonplace, :thing, :would_refuse] in found
    assert [:commonplace, :other, :denied] in found
  end

  test "the unwired list is the honest denominator on the scan's coverage" do
    # An event-shaped census can only see sites that emit events.
    # Reporting "all deny sites audited" while silently meaning "all
    # that emit events" is the silent-underreport pattern; `unwired/0`
    # is where that gap is stated instead of hidden.
    for site <- DenySites.unwired() do
      assert is_nil(site.event),
             "an entry in unwired/0 that HAS an event belongs in audited/0 or exempt/0"
    end
  end
end
