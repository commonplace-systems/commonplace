defmodule Commonplace.Bd.StrandedDetectorCoverageTest do
  @moduledoc """
  ANSWERS two empirical questions about a design ruling on CX-di2m
  (a dependency CYCLE created by merging two individually-legal
  edits — see `Commonplace.Bd.MergeCycleInvariantTest`, which proves
  the merge really does produce a live A<->B cycle that no write
  path ever re-validates).

  The ruling claims CX-di2m is "survivable as it stands" because
  "the stranded-set alarm is precisely the existing detector for
  it" — i.e. `Commonplace.Bd.Frontier.stranded_components/2`. That
  function's actual logic (read from source, apps/commonplace/lib/
  commonplace/bd/frontier.ex:137-152): build an UNDIRECTED adjacency
  over local `needs` edges, take connected components over ALL
  issues, and flag a component iff `has_open and not has_ready`
  (at least one open member, AND zero ready members).

  ## Q1 — does the detector fire, and when does it stop firing?

  Test 1 is the POSITIVE CONTROL: an isolated A<->B cycle, nothing
  else attached. Establishes the detector genuinely catches this
  shape.

  Test 2 tests the suspected gap: the SAME cycle, but with a third,
  READY ticket C pulled into the same undirected component.

  Construction: `needs_satisfied?/2` requires ALL of an issue's own
  `needs` entries to resolve to closed/wontfix, so if C's readiness
  depended on an entry pointing at A or B (both open), C would be
  BLOCKED, not ready — that would defeat the construction. Instead,
  C is left with an EMPTY `needs` list (open + no needs -> trivially
  ready, `Enum.all?([], ...) == true`), and A gains a SECOND needs
  entry pointing at C, on top of A's existing edge to B. Adjacency in
  `build_adjacency/1` is symmetric and keyed off both issues' `needs`
  lists regardless of which side names the other, so this A-C entry
  pulls C into the same connected component as {A, B} without ever
  touching C's own `needs` — C stays ready; A and B stay blocked (A
  already had one unsatisfied entry pointing at B; adding a second
  unsatisfied entry pointing at C changes nothing about A's own
  readiness).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Frontier, Issue}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_stranded_coverage_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_stranded_coverage_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  describe "Q1 — isolated cyclic pair (positive control)" do
    test "an isolated A<->B needs-cycle, nothing else connected, is reported as stranded", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      # Land both edges directly (bypassing WriteGuard, exactly as the
      # merge in MergeCycleInvariantTest does in practice) — the point
      # here is not HOW the cycle formed, only what the detector does
      # once it exists.
      {:ok, _a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)
      {:ok, _b} = Issue.update(ctx.root, b.id, %{needs: [%{"ticket" => a.id}]}, ctx.store)

      # Confirm both are BLOCKED (neither's needs entry resolves to a
      # closed/wontfix target — each points at the other, and both are
      # open), i.e. the ready set is genuinely empty for this pair.
      ready = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id) |> MapSet.new()
      blocked = Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(ready, a.id)
      refute MapSet.member?(ready, b.id)
      assert MapSet.member?(blocked, a.id)
      assert MapSet.member?(blocked, b.id)

      components = Frontier.stranded_components(ctx.root, ctx.store)

      # THE CLAIM'S POSITIVE HALF: a component containing both A and B,
      # with zero ready members, IS flagged. This establishes the
      # detector genuinely fires for this exact shape, so Test 2's
      # result (if it differs) is a real gap, not a broken harness.
      matching = Enum.filter(components, fn c -> a.id in c and b.id in c end)
      assert length(matching) == 1
      [component] = matching
      assert MapSet.new(component) == MapSet.new([a.id, b.id])
    end
  end

  describe "Q2 — the suspected gap: a ready ticket sharing the component" do
    test "the same cycle, with a ready ticket C pulled into the same undirected component, " <>
           "is NOT reported — the detector's has_ready check is component-wide, not per-cycle",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)

      # The cycle: A <-> B.
      {:ok, _a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)
      {:ok, _b} = Issue.update(ctx.root, b.id, %{needs: [%{"ticket" => a.id}]}, ctx.store)

      # Pull C into the SAME undirected component by having A also
      # need C (a second needs-entry on A, alongside A's existing
      # needs-B entry). This creates an A-C adjacency edge without
      # touching C's OWN needs at all, so C's readiness (its needs
      # list is empty) is untouched by this edge — adjacency in
      # `build_adjacency/1` is symmetric regardless of which side
      # names the other.
      {:ok, a2} =
        Issue.update(
          ctx.root,
          a.id,
          %{needs: [%{"ticket" => b.id}, %{"ticket" => c.id}]},
          ctx.store
        )

      assert length(a2.needs) == 2

      # Verify readiness with the real ready/blocked walk, not assumed:
      ready = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id) |> MapSet.new()
      blocked = Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id) |> MapSet.new()

      # C: open, empty needs -> Enum.all?([], ...) == true -> READY.
      assert MapSet.member?(ready, c.id)
      refute MapSet.member?(blocked, c.id)

      # A: open, needs [B (open, unsatisfied), C (open, unsatisfied)]
      # -> BLOCKED (unchanged by adding the second entry — one
      # unsatisfied entry was already enough).
      assert MapSet.member?(blocked, a.id)
      refute MapSet.member?(ready, a.id)

      # B: open, needs [A (open, unsatisfied)] -> still BLOCKED.
      assert MapSet.member?(blocked, b.id)
      refute MapSet.member?(ready, b.id)

      components = Frontier.stranded_components(ctx.root, ctx.store)

      # THE UNDIRECTED COMPONENT that now exists is {A, B, C}: A-B
      # (mutual cycle edge) and A-C (the new edge) both land in the
      # SAME adjacency map entry for A, so `connected_components/2`'s
      # BFS walks A -> B -> (back to A, already visited) and A -> C in
      # one traversal, producing one 3-member component, not two.
      matching_abc =
        Enum.filter(components, fn comp -> MapSet.new(comp) == MapSet.new([a.id, b.id, c.id]) end)

      # THE VERDICT: `stranded_components/2` filters each component by
      # `has_open and not has_ready` — component-WIDE, not per-cycle.
      # {A, B, C} has an open member (A, B are both open) AND a ready
      # member (C) -> `has_ready` is true for the WHOLE component ->
      # `not has_ready` is false -> the filter drops it. The live
      # A<->B cycle inside this component is real (confirmed above:
      # both blocked, neither ready, exactly as in Test 1) but it is
      # no longer visible in `stranded_components/2`'s output at all,
      # because ONE unrelated ready ticket sharing an edge with either
      # cycle member is enough to silence the alarm for the entire
      # component including the cycle.
      assert matching_abc == []

      # Confirm this isn't simply "A and B individually don't appear
      # in ANY reported component" for some other reason (e.g. they
      # got split into a different shape) — walk every reported
      # component and show neither A nor B appears in any of them.
      refute Enum.any?(components, fn comp -> a.id in comp end)
      refute Enum.any?(components, fn comp -> b.id in comp end)

      # SO: the ruling's claim ("the stranded-set alarm is precisely
      # the existing detector for it") does NOT hold generally. It
      # holds only when the cyclic component happens to be isolated
      # from every ready ticket in the whole `needs` graph. As soon as
      # a cyclic pair shares even one undirected edge with something
      # ready — plausible at 786-issue scale, where a single ticket
      # commonly has several needs/needed-by edges into an otherwise
      # healthy graph — the detector goes silent for that cycle while
      # it is still live and still unreachable.
    end
  end

  describe "Q2 (cost) — 786-issue-scale corpus" do
    @describetag :scale
    # 600_000 was a fixed budget sitting ~13% above the actual cost: the
    # corpus build alone measured 522s on the scale lane's first CI run
    # (2026-08-18) and crossed 600s outright on a loaded local host. A
    # budget that close to the workload is the flake class the S-timing
    # round retired — 2.3× the measured build cost, still well inside the
    # lane's 60-minute job bound.
    @tag timeout: 1_200_000

    test "stranded_components/2 and the ready/blocked walk over a realistic-scale corpus", ctx do
      n = scale("SCALE_STRANDED_N", 800)

      # The CREATE calls below carry the CX-gc7q boundary deadline instead
      # of GenServer.call's invisible 5,000ms default. At this scale a
      # single late create legitimately crosses 5s on a loaded host
      # (measured 2026-08-18: the default fired ~601s into the build,
      # inside add_issue_entry — the CX-7b53 budget-nesting shape, the
      # raised test budget revealing the one beneath). Creates ONLY:
      # CX-gc7q is scoped to the ticket-create chain, and Issue.update
      # forwards the deadline WITHOUT its :ticket_create_document
      # companion — Keyword.fetch! crashes (measured same day). Updates
      # here write short per-issue chains whose cost does not grow with
      # the corpus, so the 5s default is honest for them. The deadline
      # sits just under the test's own budget so exhaustion produces the
      # NAMED deadline error, not an anonymous ExUnit timeout.
      write_opts = [
        ticket_create_deadline: System.monotonic_time(:millisecond) + 1_140_000
      ]

      # Build N issues. Every 5th issue needs the previous one (a
      # sparse chain of satisfied edges: earlier tickets get closed as
      # we go, so most needs edges resolve and most tickets end up
      # ready — "a realistic sprinkling," not a dense or fully cyclic
      # graph), plus ONE deliberate 2-cycle at the end (mirrors
      # CX-di2m) to keep `stranded_components/2` doing real work, not
      # just walking an all-isolated-nodes graph.
      # :timer.tc returns {elapsed_us, result} — TIME FIRST. The original
      # destructure here was reversed, and no run ever reached it to say so:
      # the corpus build alone crossed the old 600s budget on every loaded
      # local run, so the first execution of the line below was the scale
      # lane's first CI dispatch (2026-08-18, Enumerable-on-522394522).
      {elapsed_build_us, ids} =
        :timer.tc(fn ->
          Enum.reduce(1..n, [], fn i, acc ->
            {:ok, issue, _} = Issue.create(ctx.root, %{title: "T#{i}"}, ctx.store, write_opts)

            issue =
              if rem(i, 5) == 0 and acc != [] do
                prev_id = hd(acc)

                {:ok, updated} =
                  Issue.update(ctx.root, issue.id, %{needs: [%{"ticket" => prev_id}]}, ctx.store)

                updated
              else
                issue
              end

            # Close every 7th issue so a meaningful fraction of needs
            # edges above actually resolve (satisfied), producing a mix
            # of ready and blocked tickets rather than an all-blocked
            # graph.
            if rem(i, 7) == 0 do
              {:ok, _} = Issue.update(ctx.root, issue.id, %{status: "closed"}, ctx.store)
            end

            [issue.id | acc]
          end)
        end)

      ids = Enum.reverse(ids)
      actual_n = length(ids)

      # The deliberate 2-cycle (CX-di2m shape), added on top of the
      # sprinkle above, isolated from the rest so it is guaranteed to
      # still show up as a stranded component regardless of what the
      # random-ish sprinkle above produced.
      {:ok, cyc_a, _} = Issue.create(ctx.root, %{title: "CYC-A"}, ctx.store, write_opts)
      {:ok, cyc_b, _} = Issue.create(ctx.root, %{title: "CYC-B"}, ctx.store, write_opts)

      {:ok, _} = Issue.update(ctx.root, cyc_a.id, %{needs: [%{"ticket" => cyc_b.id}]}, ctx.store)

      {:ok, _} = Issue.update(ctx.root, cyc_b.id, %{needs: [%{"ticket" => cyc_a.id}]}, ctx.store)

      total_n = actual_n + 2

      IO.puts(
        :stderr,
        "  [scale] built #{total_n} issues in #{Float.round(elapsed_build_us / 1_000_000, 2)} s"
      )

      {stranded_us, components} =
        :timer.tc(fn -> Frontier.stranded_components(ctx.root, ctx.store) end)

      {ready_us, _ready} = :timer.tc(fn -> Frontier.ready_walk(ctx.root, ctx.store) end)
      {blocked_us, _blocked} = :timer.tc(fn -> Frontier.blocked_walk(ctx.root, ctx.store) end)

      IO.puts(:stderr, "  [scale] N=#{total_n} stranded_components/2: #{stranded_us} us")
      IO.puts(:stderr, "  [scale] N=#{total_n} ready_walk/2: #{ready_us} us")
      IO.puts(:stderr, "  [scale] N=#{total_n} blocked_walk/2: #{blocked_us} us")

      # The deliberate isolated cycle must still be caught (sanity
      # check that the timed calls above did real, correct work, not
      # just fast-pathing on an empty/degenerate graph).
      assert Enum.any?(components, fn comp ->
               MapSet.new(comp) == MapSet.new([cyc_a.id, cyc_b.id])
             end)
    end

    defp scale(env, default) do
      case System.get_env(env) do
        nil -> default
        v -> String.to_integer(v)
      end
    end
  end
end
