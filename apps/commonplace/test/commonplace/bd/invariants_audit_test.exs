defmodule Commonplace.Bd.InvariantsAuditTest do
  @moduledoc """
  CX-gvbf follow-up: tests for the three NEW pure checks added to
  `Commonplace.Bd.Invariants` (`parses/3`, `acyclic/2`, `ref_typed/3`)
  plus `check_all/2`, the standing-audit entry point `bin/bd-invariants`
  calls.

  Isolation mirrors `freeze_pin_test.exs` / `merge_cycle_invariant_test.exs`
  — own tmp-dir `CommitStore` and bd root, never the real
  `.commonplace/` or `dogfood-mud/` workspace.

  Every check gets BOTH directions (a violating case and a clean
  case) — a checker never observed to fail is not a checker.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Invariants, Issue, Schemas, WriteGuard, Workspace}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Fork, Merge, Schema}
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_invariants_audit_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_invariants_audit_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  describe "parses/3" do
    test "a clean ticket parses -> :ok", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      assert :ok == Invariants.parses(ctx.root, a.id, ctx.store)
    end

    test "a ticket id that doesn't resolve at all -> {:error, :not_found}, not a violation",
         ctx do
      assert {:error, :not_found} == Invariants.parses(ctx.root, "CX-nonexistent", ctx.store)
    end

    test "the real CX-o3ar corruption class: concurrent whole-blob rewrites of the same " <>
           "__issue.json leaf concatenate into unparseable JSON, and parses/3 catches it",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      # Same fork/diverge/merge construction as freeze_pin_test.exs's
      # positive control: fork at the common base, close A on line 1,
      # set A in_progress on line 2 (the fork) while it's still open
      # there, then merge. Both lines rewrite the SAME Yjs Text leaf
      # (__issue.json is one text CRDT holding the whole serialized
      # issue), so the merge concatenates both complete JSON blobs
      # rather than producing a semantically-merged, parseable result.
      fork_root = Fork.fork_directory(ctx.root, ctx.store)

      {:ok, a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)
      assert a_closed.status == "closed"

      {:ok, a_on_fork_before} = Issue.show(fork_root, a.id, ctx.store)
      assert a_on_fork_before.status == "open"
      {:ok, _a_line2} = Issue.update(fork_root, a.id, %{status: "in_progress"}, ctx.store)

      {:ok, report} = Merge.merge(fork_root, ctx.root, ctx.store)
      assert report.conflicts == []

      # Confirm the corruption really landed (not asserting blind —
      # same double-check freeze_pin_test.exs does): the raw doc
      # content fails to decode as JSON at all.
      {:ok, dir_uuid} = Workspace.issue_dir_uuid(ctx.root, a.id, ctx.store)
      {:ok, schema} = Schemas.load_dir_schema(dir_uuid, ctx.store)
      {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
      {:ok, doc} = DocBuilder.reconstruct_doc(ctx.store, entry.node_id)
      raw = Commonplace.Document.ContentType.get_content(doc)
      assert {:error, %Jason.DecodeError{}} = Jason.decode(raw)

      assert {:violation, details} = Invariants.parses(ctx.root, a.id, ctx.store)
      assert details.issue_id == a.id
      assert match?(%Jason.DecodeError{}, details.error)
    end
  end

  describe "acyclic/2" do
    test "the reason this check exists: a cycle embedded in a component that ALSO contains " <>
           "a ready ticket must be DETECTED (this is exactly what stranded_components/2 " <>
           "misses — StrandedDetectorCoverageTest's Q2)",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)

      # The cycle: A <-> B.
      {:ok, _a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)
      {:ok, _b} = Issue.update(ctx.root, b.id, %{needs: [%{"ticket" => a.id}]}, ctx.store)

      # C: open, empty needs -> ready. Pull C into the same UNDIRECTED
      # component as {A, B} via a second needs-entry on A -> C,
      # without touching C's own needs (mirrors
      # StrandedDetectorCoverageTest's Q2 construction exactly).
      {:ok, a2} =
        Issue.update(
          ctx.root,
          a.id,
          %{needs: [%{"ticket" => b.id}, %{"ticket" => c.id}]},
          ctx.store
        )

      assert length(a2.needs) == 2

      # Confirm the gap this check exists to close: stranded_components/2
      # does NOT report the A<->B cycle once C shares its component.
      components = Commonplace.Bd.Frontier.stranded_components(ctx.root, ctx.store)
      refute Enum.any?(components, fn comp -> a.id in comp end)
      refute Enum.any?(components, fn comp -> b.id in comp end)

      # THE VERDICT: acyclic/2, being a proper DIRECTED walk (not
      # component-based), catches the cycle anyway.
      assert {:violation, %{cycles: cycles}} = Invariants.acyclic(ctx.root, ctx.store)
      assert length(cycles) > 0
      assert Enum.any?(cycles, fn cycle -> a.id in cycle and b.id in cycle end)
    end

    test "a legal DAG (A needs B, C needs B) reports no violation", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)

      {:ok, _a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)
      {:ok, _c} = Issue.update(ctx.root, c.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)

      assert :ok == Invariants.acyclic(ctx.root, ctx.store)
    end

    test "a cross-repo needs entry (carries a \"repo\" key) is excluded as an unwalkable leaf " <>
           "and never participates in the cycle walk",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      # A "needs" a foreign-repo ticket whose id happens to collide
      # with A's own id in a different repo namespace — if the walk
      # incorrectly treated this as a local edge, it would find a
      # bogus self-cycle. It must not.
      {:ok, _a} =
        Issue.update(
          ctx.root,
          a.id,
          %{needs: [%{"ticket" => a.id, "repo" => "some-other-repo"}]},
          ctx.store
        )

      assert :ok == Invariants.acyclic(ctx.root, ctx.store)
    end
  end

  describe "ref_typed/3" do
    test "a resting-state needs shape violation is caught (unexpected key on a needs entry)",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      # Land a malformed needs entry directly (bypassing WriteGuard —
      # exactly the point of a resting-state audit: it exists to catch
      # writes that landed by some path other than the gated one).
      bad_needs = [%{"ticket" => "CX-1", "bogus_key" => "x"}]
      {:ok, a_bad} = Issue.update(ctx.root, a.id, %{needs: bad_needs}, ctx.store)
      assert a_bad.needs == bad_needs

      # Confirm WriteGuard itself would have refused this shape on a
      # real write, so the check below is re-judging the SAME rule,
      # not a different one.
      assert {:error, reason} =
               WriteGuard.check(a, %{needs: bad_needs}, ctx.root, ctx.store, allow: [])

      assert reason =~ "unexpected keys"

      assert {:violation, details} = Invariants.ref_typed(ctx.root, a.id, ctx.store)
      assert details.issue_id == a.id
      assert details.error =~ "unexpected keys"
    end

    test "a resting-state done_witness shape violation is caught (non-hex entry)", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      {:ok, a_bad} = Issue.update(ctx.root, a.id, %{done_witness: ["NOT-HEX!"]}, ctx.store)
      assert a_bad.done_witness == ["NOT-HEX!"]

      assert {:error, _reason} =
               WriteGuard.check(a, %{done_witness: ["NOT-HEX!"]}, ctx.root, ctx.store,
                 allow: [:done_witness]
               )

      assert {:violation, details} = Invariants.ref_typed(ctx.root, a.id, ctx.store)
      assert details.issue_id == a.id
      assert details.error =~ "lowercase hex"
    end

    test "a clean ticket (valid needs + done_witness shapes) -> :ok", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      {:ok, a2} =
        Issue.update(
          ctx.root,
          a.id,
          %{needs: [%{"ticket" => b.id}], done_witness: ["deadbeef"]},
          ctx.store
        )

      assert a2.needs == [%{"ticket" => b.id}]

      assert :ok == Invariants.ref_typed(ctx.root, a.id, ctx.store)
    end

    test "an issue id that doesn't resolve -> {:error, :not_found}", ctx do
      assert {:error, :not_found} == Invariants.ref_typed(ctx.root, "CX-nonexistent", ctx.store)
    end
  end

  describe "check_all/2" do
    test "runs every invariant over the whole corpus and reports a structured, per-hit result",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, _c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)

      # One deliberate violation: a bad needs shape on A.
      {:ok, _} =
        Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => "x", "bogus" => 1}]}, ctx.store)

      # One deliberate cycle: B needs itself directly.
      {:ok, _} = Issue.update(ctx.root, b.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)

      result = Invariants.check_all(ctx.root, ctx.store)

      assert %{parses: _, closed_matches_pin: _, ref_typed: _, acyclic: _} = result

      assert result.parses.checked == 3
      assert result.parses.violations == []

      assert result.ref_typed.checked == 3
      assert length(result.ref_typed.violations) == 1
      assert hd(result.ref_typed.violations).issue_id == a.id

      assert result.acyclic.checked == 1
      assert length(result.acyclic.violations) == 1
      flattened_cycles = hd(result.acyclic.violations).cycles |> List.flatten()
      assert b.id in flattened_cycles
    end

    test "a fully clean corpus reports zero violations across every invariant", ctx do
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
