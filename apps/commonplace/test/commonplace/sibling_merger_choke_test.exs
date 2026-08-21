defmodule Commonplace.SiblingMergerChokeTest do
  @moduledoc """
  BUILD-1 §4 condition #2 (plan #13772): the sole-caller choke.

  Leg 5 established that `SiblingMerger.maybe_merge_siblings/3` short-circuits
  `latest_commit == :none → {:ok, :no_siblings}` (sibling_merger.ex:115)
  BEFORE `sibling_ids_for/3`, its `:latest` guard, or `scan_sibling_ids/3`.
  That short-circuit is what keeps the nil-`:latest` population out of the
  fallback's scope. Today the scan-fallback is a BELT covering that
  population by accident; §4 removes it, making the `:115` short-circuit the
  SOLE protection — load-bearing alone.

  So this guard binds the PROPERTY the removal depends on: no code may reach
  `sibling_ids_for`/`scan_sibling_ids` except through the `:115`-guarded
  entry. `sibling_ids_for`/`scan_sibling_ids` are `defp`, so an external
  bypass is already impossible; the residual risk is a FUTURE function INSIDE
  the module that calls `sibling_ids_for` directly and reintroduces the
  exposure the fallback was silently covering — a failure that would be
  QUIET post-§4. This scan makes that a RED test, not an incident.

  Same shape as `invariant_choke_test`'s single-funnel scan: track the
  enclosing function per line, attribute each call site, assert the set of
  enclosing functions is exactly the guarded one, and prove the scanner can
  go red with a synthetic offender.
  """
  use ExUnit.Case, async: true

  # callee => the ONLY function permitted to call it. Bound to the property
  # (the guarded entry), not to today's single presence caller.
  @allowed_callers %{
    "sibling_ids_for" => "maybe_merge_siblings",
    "scan_sibling_ids" => "sibling_ids_for"
  }

  defp merger_path do
    Path.expand(Path.join(__DIR__, "../../lib/commonplace/sibling_merger.ex"))
  end

  # Scan a source file for CALLS (not definitions) of the two functions,
  # each tagged with its enclosing def/defp.
  defp sibling_merge_calls(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {line, lineno}, {current_function, hits} ->
      current_function =
        case Regex.run(~r/^\s{0,4}defp?\s+([a-z_][a-zA-Z0-9_?!]*)/, line) do
          [_, fun] -> fun
          nil -> current_function
        end

      hits =
        Enum.reduce(Map.keys(@allowed_callers), hits, fn callee, acc ->
          if calls?(line, callee) do
            [%{callee: callee, function: current_function, line: lineno, text: line} | acc]
          else
            acc
          end
        end)

      {current_function, hits}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # A CALL to `name(` that is NOT the `defp name(` definition line.
  defp calls?(line, name) do
    String.contains?(line, name <> "(") and
      not Regex.match?(~r/^\s{0,4}defp?\s+#{Regex.escape(name)}\s*\(/, line)
  end

  test "no call to sibling_ids_for/scan_sibling_ids bypasses its guarded caller" do
    offenders =
      merger_path()
      |> sibling_merge_calls()
      |> Enum.reject(fn %{callee: callee, function: function} ->
        function == @allowed_callers[callee]
      end)

    assert offenders == [],
           """
           A call to a sibling-merge internal was found OUTSIDE its guarded
           caller. After §4 removes the scan-fallback, `maybe_merge_siblings/3`'s
           :115 `latest_commit == :none` short-circuit is the SOLE protection for
           the nil-`:latest` population — a caller reaching `sibling_ids_for`
           without passing that short-circuit reintroduces the exposure the
           fallback was covering, and it fails QUIET. Route the new path through
           `maybe_merge_siblings/3`, or update this choke deliberately.

           Offending sites:
           #{Enum.map_join(offenders, "\n", fn o -> "  #{o.line} #{o.callee} called in #{o.function}\n    #{String.trim(o.text)}" end)}
           """
  end

  test "the guarded call sites ARE present (the scan is not vacuously green)" do
    calls = sibling_merge_calls(merger_path())
    # Prove the corpus is non-empty: both internals ARE called somewhere,
    # each from its guarded caller — else "0 offenders" could be "0 calls".
    assert Enum.any?(
             calls,
             &(&1.callee == "sibling_ids_for" and &1.function == "maybe_merge_siblings")
           )

    assert Enum.any?(
             calls,
             &(&1.callee == "scan_sibling_ids" and &1.function == "sibling_ids_for")
           )
  end

  describe "the scanner itself can go red" do
    test "recognises a call and rejects the definition line" do
      assert calls?("        sibling_ids_for(store, doc_uuid, latest)", "sibling_ids_for")
      refute calls?("  defp sibling_ids_for(store, doc_uuid, latest) do", "sibling_ids_for")
    end

    test "a synthetic rogue caller is reported with its function name" do
      tmp = Path.join(System.tmp_dir!(), "cp_sib_choke_#{:rand.uniform(1_000_000_000)}.ex")

      File.write!(tmp, """
      defmodule Fake do
        def maybe_merge_siblings(store, doc_uuid) do
          sibling_ids_for(store, doc_uuid, nil)
        end

        defp bypass(store, doc_uuid) do
          sibling_ids_for(store, doc_uuid, nil)
        end

        defp sibling_ids_for(_s, _d, _l), do: MapSet.new()
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)

      offenders =
        tmp
        |> sibling_merge_calls()
        |> Enum.reject(fn %{callee: callee, function: function} ->
          function == @allowed_callers[callee]
        end)

      assert [%{callee: "sibling_ids_for", function: "bypass"}] = offenders
    end
  end
end
