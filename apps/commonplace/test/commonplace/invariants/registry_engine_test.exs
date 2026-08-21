defmodule Commonplace.Invariants.RegistryEngineTest do
  @moduledoc """
  CX-9fyz: coverage for the four brand-new modules under
  `Commonplace.Invariants.{Invariant, Mode, Registry, Engine}` plus the
  `Commonplace.Bd.Invariants.check_all/2` adapter that was rewired to
  delegate to the engine.

  Governing rule (this repo's dominant defect class,
  `reference_checks_that_cannot_fail.md`): a check that cannot fail is
  worse than no check. Every assertion below is exercised in BOTH
  directions where the thing under test can meaningfully go wrong — a
  clean case that passes and a real violating case that fires — with
  the pre-declared control called out in a comment wherever it isn't
  obvious from the assertion itself.

  Fixture idioms (tmp-dir `CommitStore`, fresh bd root, `Issue.create`,
  fork/diverge/merge corruption constructions) are copied from
  `commonplace/test/commonplace/bd/invariants_audit_test.exs` and
  `commonplace/test/commonplace/bd/freeze_pin_test.exs` on purpose —
  those are the established idioms for this fixture, not reinvented
  here.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Invariants, Issue}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{Fork, Merge, Schema}
  alias Commonplace.Invariants.{Engine, Invariant, Mode, Registry}
  alias Yelixer.Encoding

  # ------------------------------------------------------------------
  # A. Invariant.new!/1 — loud, one distinguishable failure at a time.
  # ------------------------------------------------------------------

  describe "Invariant.new!/1 validation" do
    defp valid_attrs do
      [
        name: :test_invariant,
        scope: %{domain: :test, granularity: :per_subject},
        enumerate: fn _ctx -> [] end,
        check: fn _ctx, _subject -> :ok end,
        responses: [:alarm],
        deferral: :immediate,
        owner: "test-owner",
        doc: "why this exists"
      ]
    end

    test "a valid minimal invariant builds" do
      inv = Invariant.new!(valid_attrs())
      assert %Invariant{name: :test_invariant} = inv
      assert inv.responses == [:alarm]
      assert inv.deferral == :immediate
    end

    test "missing required field raises, naming the field" do
      attrs = Keyword.delete(valid_attrs(), :name)

      assert_raise ArgumentError, ~r/missing required field/, fn ->
        Invariant.new!(attrs)
      end
    end

    test "unknown response atom raises" do
      attrs = Keyword.put(valid_attrs(), :responses, [:alarm, :bogus_response])

      assert_raise ArgumentError, ~r/unknown response/, fn ->
        Invariant.new!(attrs)
      end
    end

    test "responses not containing :alarm raises" do
      attrs = Keyword.put(valid_attrs(), :responses, [:block_promotion])

      assert_raise ArgumentError, ~r/does not contain :alarm/, fn ->
        Invariant.new!(attrs)
      end
    end

    test "unknown deferral class raises" do
      attrs = Keyword.put(valid_attrs(), :deferral, :sometimes)

      assert_raise ArgumentError, ~r/unknown deferral class/, fn ->
        Invariant.new!(attrs)
      end
    end

    test ":per_subject granularity with nil :enumerate raises" do
      attrs =
        valid_attrs()
        |> Keyword.put(:scope, %{domain: :test, granularity: :per_subject})
        |> Keyword.put(:enumerate, nil)

      assert_raise ArgumentError, ~r/requires a non-nil :enumerate/, fn ->
        Invariant.new!(attrs)
      end
    end

    test ":whole granularity with a non-nil :enumerate raises" do
      attrs =
        valid_attrs()
        |> Keyword.put(:scope, %{domain: :test, granularity: :whole})
        |> Keyword.put(:enumerate, fn _ctx -> [] end)

      assert_raise ArgumentError, ~r/requires :enumerate to be nil/, fn ->
        Invariant.new!(attrs)
      end
    end

    test "a check fun of the wrong arity raises" do
      # scope says :per_subject (expects arity-2 check), check is arity-1.
      attrs = Keyword.put(valid_attrs(), :check, fn _ctx -> :ok end)

      assert_raise ArgumentError, ~r/must be an arity-2 fun/, fn ->
        Invariant.new!(attrs)
      end
    end

    test "empty :doc raises" do
      attrs = Keyword.put(valid_attrs(), :doc, "")

      assert_raise ArgumentError, ~r/:doc must be a non-empty string/, fn ->
        Invariant.new!(attrs)
      end
    end
  end

  # ------------------------------------------------------------------
  # B. The registry as shipped.
  # ------------------------------------------------------------------

  describe "Registry" do
    test "all/0 returns exactly the six expected names" do
      names = Registry.all() |> Enum.map(& &1.name) |> Enum.sort()

      assert names == [
               :bd_acyclic,
               :bd_closed_matches_pin,
               :bd_parses,
               :bd_ref_typed,
               :chit_ancestry,
               :commit_accepted_heads_antichain
             ]
    end

    test "for_domain(:chit) returns the chit ancestry invariant" do
      names = Registry.for_domain(:chit) |> Enum.map(& &1.name)
      assert names == [:chit_ancestry]
    end

    test "for_domain(:commit) returns the accepted-head antichain invariant" do
      names = Registry.for_domain(:commit) |> Enum.map(& &1.name)
      assert names == [:commit_accepted_heads_antichain]
    end

    test "every entry is a %Invariant{} that survived validation" do
      Enum.each(Registry.all(), fn entry ->
        assert %Invariant{} = entry
      end)
    end

    test "PRE-DECLARED STEP-1 PIN: every entry's responses is exactly [:alarm]" do
      # This test is designed to go RED the moment someone declares
      # :block_promotion or a repair response on a registry entry
      # before the enforcement wiring that would perform it exists —
      # that is its purpose, not an incidental assertion (see
      # Registry's moduledoc "Step 1 scope: bd only, alarm-only").
      Enum.each(Registry.all(), fn entry ->
        assert entry.responses == [:alarm],
               "#{entry.name} declared #{inspect(entry.responses)} — step 1 must be [:alarm] only"
      end)
    end

    test "bd_closed_matches_pin is :context_dependent; the other three are :immediate" do
      by_name = Registry.all() |> Map.new(&{&1.name, &1.deferral})

      assert by_name.bd_closed_matches_pin == :context_dependent
      assert by_name.bd_parses == :immediate
      assert by_name.bd_ref_typed == :immediate
      assert by_name.bd_acyclic == :immediate
      assert by_name.chit_ancestry == :immediate
    end

    test "fetch!/1 returns the right entry" do
      entry = Registry.fetch!(:bd_parses)
      assert entry.name == :bd_parses
    end

    test "fetch!/1 raises for an unknown name" do
      assert_raise ArgumentError, ~r/no invariant named/, fn ->
        Registry.fetch!(:not_a_real_invariant)
      end
    end

    test "validate!/1 raises on a list containing duplicate names" do
      base = [
        scope: %{domain: :test, granularity: :whole},
        enumerate: nil,
        check: fn _ctx -> :ok end,
        responses: [:alarm],
        deferral: :immediate,
        owner: "test",
        doc: "doc"
      ]

      inv1 = Invariant.new!(Keyword.put(base, :name, :dupe))
      inv2 = Invariant.new!(Keyword.put(base, :name, :dupe))

      assert_raise ArgumentError, ~r/duplicate invariant name/, fn ->
        Registry.validate!([inv1, inv2])
      end
    end

    test "for_domain(:bd) returns all four" do
      names = Registry.for_domain(:bd) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:bd_acyclic, :bd_closed_matches_pin, :bd_parses, :bd_ref_typed]
    end

    test "for_domain with an unknown domain returns []" do
      assert Registry.for_domain(:nonexistent_domain) == []
    end
  end

  # ------------------------------------------------------------------
  # C. Mode.
  # ------------------------------------------------------------------

  describe "Mode" do
    setup do
      prior_app_env = Application.get_env(:commonplace, :invariant_enforcement)
      prior_env_var = System.get_env("COMMONPLACE_INVARIANT_ENFORCEMENT")

      on_exit(fn ->
        # Always restore the prior value — a leaked app-env key (or
        # env var) is a known cross-test contamination archetype in
        # this repo (reference_flaky_ci_teardown_isolation.md).
        case prior_app_env do
          nil -> Application.delete_env(:commonplace, :invariant_enforcement)
          val -> Application.put_env(:commonplace, :invariant_enforcement, val)
        end

        case prior_env_var do
          nil -> System.delete_env("COMMONPLACE_INVARIANT_ENFORCEMENT")
          val -> System.put_env("COMMONPLACE_INVARIANT_ENFORCEMENT", val)
        end
      end)

      Application.delete_env(:commonplace, :invariant_enforcement)
      System.delete_env("COMMONPLACE_INVARIANT_ENFORCEMENT")

      :ok
    end

    test "default with nothing set is :alarm_only, source: :default" do
      assert Mode.mode() == :alarm_only
      assert Mode.describe() == %{mode: :alarm_only, source: :default, raw: nil}
      refute Mode.enforcement_active?()
    end

    test "app env :enforce reads as :enforce, source: :app_env, and is active" do
      Application.put_env(:commonplace, :invariant_enforcement, :enforce)

      assert Mode.mode() == :enforce
      assert Mode.describe() == %{mode: :enforce, source: :app_env, raw: :enforce}
      assert Mode.enforcement_active?()
    end

    test "an explicitly-set unrecognised app-env value raises, naming the bad value" do
      # THE IMPORTANT ONE: a typo'd knob silently reading as
      # :alarm_only would be an enforcement layer permanently stuck in
      # dry-run with nothing able to report it. Absence is a valid
      # default; an unrecognised VALUE must be loud instead.
      Application.put_env(:commonplace, :invariant_enforcement, :bogus_mode)

      assert_raise ArgumentError, ~r/:bogus_mode/, fn ->
        Mode.mode()
      end
    end

    test "env var path: \"enforce\" reads as :enforce, source: :env_var, when app env is unset" do
      System.put_env("COMMONPLACE_INVARIANT_ENFORCEMENT", "enforce")

      assert Mode.describe() == %{mode: :enforce, source: :env_var, raw: "enforce"}
      assert Mode.enforcement_active?()
    end

    test "env var path: an unrecognised string raises, naming the bad value" do
      System.put_env("COMMONPLACE_INVARIANT_ENFORCEMENT", "not-a-real-mode")

      assert_raise ArgumentError, ~r/not-a-real-mode/, fn ->
        Mode.mode()
      end
    end

    test "app env takes precedence over the env var when both are set" do
      System.put_env("COMMONPLACE_INVARIANT_ENFORCEMENT", "enforce")
      Application.put_env(:commonplace, :invariant_enforcement, :alarm_only)

      assert Mode.describe() == %{mode: :alarm_only, source: :app_env, raw: :alarm_only}
    end
  end

  # ------------------------------------------------------------------
  # D + E fixture: a real bd corpus (mirrors invariants_audit_test.exs
  # / freeze_pin_test.exs exactly).
  # ------------------------------------------------------------------

  defp bd_setup(tag) do
    dir = Path.join(System.tmp_dir!(), "cp_registry_engine_#{tag}_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_registry_engine_#{tag}_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  defp engine_ctx(ctx), do: %{root_uuid: ctx.root, store: ctx.store}

  describe "Engine over a real bd corpus" do
    setup do
      bd_setup("engine")
    end

    test "a clean corpus: every invariant reports violations: [] and ok == checked", ctx do
      {:ok, _a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, _b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)
      {:ok, _c_closed} = Issue.close(ctx.root, c.id, [reason: "done"], ctx.store)

      result = Engine.run(engine_ctx(ctx), domain: :bd)

      # THE POSITIVE CONTROL: this proves the checks CAN say "ok" and
      # that enumeration is non-empty — a run over an empty corpus
      # would report "0 violations out of 0 checked", which renders
      # identically to a real clean pass unless checked > 0 is
      # asserted explicitly (per-hit-shapes discipline,
      # reference_counts_need_shapes.md).
      for name <- [:bd_parses, :bd_ref_typed, :bd_closed_matches_pin] do
        r = result.results[name]
        assert r.violations == [], "#{name} unexpectedly violated: #{inspect(r.violations)}"
        assert r.checked > 0, "#{name}: checked must be > 0 for this to mean anything"
        assert r.ok == r.checked
      end

      acyclic = result.results[:bd_acyclic]
      assert acyclic.violations == []
      assert acyclic.checked == 1
      assert acyclic.ok == 1
    end

    test "bd_parses fires on the real CX-o3ar corruption class (concatenated JSON blobs)", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      fork_root = Fork.fork_directory(ctx.root, ctx.store)
      {:ok, a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)
      assert a_closed.status == "closed"

      {:ok, a_on_fork_before} = Issue.show(fork_root, a.id, ctx.store)
      assert a_on_fork_before.status == "open"
      {:ok, _a_line2} = Issue.update(fork_root, a.id, %{status: "in_progress"}, ctx.store)

      {:ok, report} = Merge.merge(fork_root, ctx.root, ctx.store)
      assert report.conflicts == []

      result = Engine.run_one(:bd_parses, engine_ctx(ctx))

      assert length(result.violations) == 1
      violation = hd(result.violations)
      # Per-hit detail, not a count — and carries the engine's :subject key.
      assert violation.subject == a.id
      assert violation.issue_id == a.id
      assert match?(%Jason.DecodeError{}, violation.error)
    end

    test "bd_acyclic fires on a real directed cycle", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      {:ok, _a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)
      {:ok, _b} = Issue.update(ctx.root, b.id, %{needs: [%{"ticket" => a.id}]}, ctx.store)

      result = Engine.run_one(:bd_acyclic, engine_ctx(ctx))

      assert result.checked == 1
      assert result.ok == 0
      assert [%{cycles: cycles}] = result.violations
      assert Enum.any?(cycles, fn cycle -> a.id in cycle and b.id in cycle end)
    end

    test "bd_ref_typed fires on a resting-state needs-shape violation", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      bad_needs = [%{"ticket" => "CX-1", "bogus_key" => "x"}]
      {:ok, a_bad} = Issue.update(ctx.root, a.id, %{needs: bad_needs}, ctx.store)
      assert a_bad.needs == bad_needs

      result = Engine.run_one(:bd_ref_typed, engine_ctx(ctx))

      assert length(result.violations) == 1
      violation = hd(result.violations)
      assert violation.subject == a.id
      assert violation.issue_id == a.id
      assert violation.error =~ "unexpected keys"
    end

    test "bd_closed_matches_pin fires on a doc-field-only reopen (bypassing WriteGuard)", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, _a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)

      {:ok, a_reopened} = Issue.update(ctx.root, a.id, %{status: "in_progress"}, ctx.store)
      assert a_reopened.status == "in_progress"

      result = Engine.run_one(:bd_closed_matches_pin, engine_ctx(ctx))

      assert length(result.violations) == 1
      violation = hd(result.violations)
      assert violation.subject == a.id
      assert violation.issue_id == a.id
      assert %{pinned: "closed", current: "in_progress"} = violation.fields[:status]
    end

    test "filters: only: [:bd_parses] runs exactly one", ctx do
      {:ok, _a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      result = Engine.run(engine_ctx(ctx), domain: :bd, only: [:bd_parses])

      assert Map.keys(result.results) == [:bd_parses]
    end

    test "filters: deferral: :immediate excludes :bd_closed_matches_pin", ctx do
      {:ok, _a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      result = Engine.run(engine_ctx(ctx), domain: :bd, deferral: :immediate)

      names = Map.keys(result.results) |> Enum.sort()
      refute :bd_closed_matches_pin in names
      assert names == [:bd_acyclic, :bd_parses, :bd_ref_typed]
    end

    test "filters: domain: :nonexistent yields no results", ctx do
      {:ok, _a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      result = Engine.run(engine_ctx(ctx), domain: :nonexistent)

      assert result.results == %{}
    end

    test "an unknown option key raises", ctx do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Engine.run(engine_ctx(ctx), bogus_opt: true)
      end
    end

    test "every run/2 result carries :mode and :knob", ctx do
      {:ok, _a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      result = Engine.run(engine_ctx(ctx), domain: :bd)

      assert result.mode in [:alarm_only, :enforce]
      assert %{mode: _, source: _, raw: _} = result.knob
    end

    test "unimplemented_responses is empty with the registry as shipped", ctx do
      {:ok, _a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      result = Engine.run(engine_ctx(ctx), domain: :bd)

      assert result.unimplemented_responses == %{}
    end

    test "run_one/2 on a name returns the same result map the full run produced", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      bad_needs = [%{"ticket" => "CX-1", "bogus_key" => "x"}]
      {:ok, _} = Issue.update(ctx.root, a.id, %{needs: bad_needs}, ctx.store)

      full = Engine.run(engine_ctx(ctx), domain: :bd)
      single = Engine.run_one(:bd_ref_typed, engine_ctx(ctx))

      assert single == full.results[:bd_ref_typed]
    end
  end

  # ------------------------------------------------------------------
  # E. Bd.Invariants.check_all/2 adapter equivalence.
  # ------------------------------------------------------------------

  describe "Bd.Invariants.check_all/2 adapter equivalence" do
    setup do
      bd_setup("adapter")
    end

    test "returns the legacy keys, each %{checked:, ok:, violations:, errors:}, with :issue_id on a real violation",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, _b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      bad_needs = [%{"ticket" => "CX-1", "bogus_key" => "x"}]
      {:ok, _} = Issue.update(ctx.root, a.id, %{needs: bad_needs}, ctx.store)

      result = Invariants.check_all(ctx.root, ctx.store)

      assert %{parses: _, closed_matches_pin: _, ref_typed: _, acyclic: _} = result

      Enum.each([:parses, :closed_matches_pin, :ref_typed, :acyclic], fn key ->
        assert %{checked: _, ok: _, violations: _, errors: _} = result[key]
      end)

      # Exercised on a NON-EMPTY violations list, not trivially on [] —
      # the pre-existing contract bin/bd-invariants depends on is the
      # :issue_id key, and this proves the translation actually runs.
      assert length(result.ref_typed.violations) == 1
      violation = hd(result.ref_typed.violations)
      assert violation.issue_id == a.id
      assert Map.has_key?(violation, :subject)
    end

    test "sanity: a clean corpus still reports zero violations across every legacy key", ctx do
      {:ok, _a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, _} = Issue.close(ctx.root, b.id, [reason: "done"], ctx.store)

      result = Invariants.check_all(ctx.root, ctx.store)

      assert result.parses.violations == []
      assert result.closed_matches_pin.violations == []
      assert result.ref_typed.violations == []
      assert result.acyclic.violations == []
    end
  end
end
