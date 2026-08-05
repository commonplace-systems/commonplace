defmodule Commonplace.Bd.FreezePinTest do
  @moduledoc """
  CX-gvbf (rework): the terminal-state pin now rides the SIGNED CLOSE
  COMMIT's metadata (`Commonplace.Bd.Issue.close/4`, via
  `Commonplace.Bd.Schemas.write_text_doc/4`'s `:commit_metadata` opt)
  instead of a doc field, and the pure `closed-matches-pin` alarm
  (`Commonplace.Bd.Invariants.closed_matches_pin/3`) reads it back by
  walking commit history — never from current, requester-writable doc
  state. See `Commonplace.Bd.Invariants`'s moduledoc for the full
  rationale (the doc-field version was a vulnerability: the same
  merge that reopens a ticket could rewrite the pin that would have
  caught it).

  Isolation and the fork/diverge/merge machinery mirror
  `merge_cycle_invariant_test.exs` — own tmp-dir `CommitStore` and bd
  root, never the real `.commonplace/` or `dogfood-mud/` workspace.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Invariants, Issue, Schemas}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{Fork, Merge, Schema}
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_freeze_pin_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_freeze_pin_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  # Resolves the __issue.json meta-doc's node uuid so tests can walk
  # its commit history directly, the same way
  # `Commonplace.Bd.Invariants` does internally.
  defp issue_meta_node_id(root, id, store) do
    {:ok, dir_uuid} = Commonplace.Bd.Workspace.issue_dir_uuid(root, id, store)
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
    entry.node_id
  end

  test "pin is written into the close commit's metadata, not a doc field, and round-trips through history",
       ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)

    # No such field on the struct any more.
    refute Map.has_key?(a_closed, :terminal_pin)

    # The encoded doc JSON carries no terminal_pin key either.
    encoded = Schemas.encode_issue(a_closed)
    {:ok, decoded_map} = Jason.decode(encoded)
    refute Map.has_key?(decoded_map, "terminal_pin")

    # The pin lives on the close commit's metadata instead. Walk the
    # meta-doc's commit history newest-first (as Invariants does) and
    # find the stamp.
    node_id = issue_meta_node_id(ctx.root, a.id, ctx.store)
    log = CommitStore.commit_log(ctx.store, node_id)
    stamped = Enum.find(log, &Map.has_key?(&1.metadata, :bd_terminal_pin))
    assert stamped, "expected a commit in history stamped with :bd_terminal_pin"
    assert stamped.metadata.kind == :regular

    pin_json = stamped.metadata.bd_terminal_pin
    assert is_binary(pin_json)
    {:ok, pinned_map} = Jason.decode(pin_json)

    # HONESTY NOTE: `Issue.close/4` is called here (and everywhere
    # else in this file) with no `:signing_context`, and this test
    # environment never starts `Commonplace.Store.SecretStore`, so the
    # close commit lands UNSIGNED — same default as every other
    # 3-arg `Issue.close/update` caller (see
    # `Commonplace.Bd.Issue.close/4`'s `signing_opts` plumb and
    # `issue_test.exs`'s "stays unsigned" test for the identical
    # behavior on `update/5`). The tamper-evidence claim in this
    # module's moduledoc ("unforgeable without the signer's key") is a
    # property of a SIGNED commit; an unsigned stamp is still bound
    # into the commit id via content-addressing (so it can't be
    # edited in place without changing the id), but nothing here
    # cryptographically proves WHO wrote it. A real deployment gates
    # writes through a signing_context (see `close_gate_test.exs`);
    # this test suite does not exercise that combination for
    # `Bd.Issue.close/4` specifically.
    refute stamped.signature
    refute stamped.signer_id

    # The frozen subset the invariant will later compare is exactly
    # what got persisted.
    assert pinned_map["status"] == "closed"
    assert pinned_map["done_when"] == a_closed.done_when
    assert pinned_map["done_witness"] == a_closed.done_witness

    # And the ordinary read path (through the store, not just an
    # in-memory struct) agrees with what close/4 returned.
    {:ok, a_reloaded} = Issue.show(ctx.root, a.id, ctx.store)
    assert a_reloaded.status == "closed"
  end

  describe "closed-matches-pin: the positive control (merged reopen)" do
    test "fork-diverge-merge reopen: CX-o3ar corruption masks it, Issue.show fails to parse",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      # THE DIVERGENCE, at the common base — A is still open on both
      # copies. Same structure as merge_cycle_invariant_test.exs's Q1.
      fork_root = Fork.fork_directory(ctx.root, ctx.store)

      # Line 1 (original root): close A through the real close path —
      # this is what stamps the pin into commit history.
      {:ok, a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)
      assert a_closed.status == "closed"

      # Sanity: on the LIVE closed side (no merge involved yet), the
      # invariant is satisfied.
      assert :ok == Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)

      # Line 2 (the fork): A is still open there, so setting it
      # in_progress is individually legal — WriteGuard is not even
      # consulted here (Bd.Issue is the library layer, no enforcement
      # of its own), matching how a merge path never consults it
      # either.
      {:ok, a_on_fork_before} = Issue.show(fork_root, a.id, ctx.store)
      assert a_on_fork_before.status == "open"
      {:ok, a_line2} = Issue.update(fork_root, a.id, %{status: "in_progress"}, ctx.store)
      assert a_line2.status == "in_progress"

      # THE MERGE — fold the fork (source, carrying the in_progress
      # rewrite) into the original root (target, already closed).
      {:ok, report} = Merge.merge(fork_root, ctx.root, ctx.store)
      assert report.conflicts == []

      # OBSERVED BEHAVIOUR: exactly as merge_cycle_invariant_test.exs's
      # Q1 documents, __issue.json is one Yjs Text CRDT leaf and both
      # lines' writes are full-blob rewrites, so the merge concatenates
      # both complete JSON documents rather than producing a
      # semantically-merged (and parseable) reopened Issue. Reading it
      # back through the ordinary path fails to parse at all:
      read_result = Issue.show(ctx.root, a.id, ctx.store)
      assert {:error, %Jason.DecodeError{}} = read_result

      # This is EXPECTED, not a gap in this test: `closed_matches_pin/3`
      # itself calls `Issue.show/3` internally, so it surfaces the same
      # decode error rather than a `%{}` violation map — there is no
      # decoded `%Issue{}` for it to compare. The corruption (CX-o3ar)
      # currently masks the reopen at the read layer, before the
      # invariant ever gets a chance to compare. `closed_matches_pin/3`
      # cannot fire on a document that never became a struct.
      assert {:error, %Jason.DecodeError{}} = Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)

      # That is exactly the situation minimal-diff (write_text_doc/4's
      # warning comment) will change: once concurrent writes merge into
      # a WELL-FORMED, silently-reopened Issue instead of garbage, THIS
      # test's assertions change to `{:ok, reopened_issue}` /
      # `{:violation, _}`. The clean-reopen case below proves that half
      # of the claim now, directly, so the invariant's behaviour is
      # verified even though the live merge can't exercise it yet.
    end

    test "THE FIX'S OWN TEST: a doc-field-only reopen (bypassing WriteGuard) cannot bless itself — the verdict comes from signed history",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, _a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)
      assert :ok == Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)

      # A real library write (Bd.Issue does no enforcement of its own —
      # same fact the merge-path gap relies on) that overwrites `status`
      # back to "in_progress" on the ALREADY-CLOSED issue, bypassing
      # WriteGuard entirely — this is the clean (parseable) version of
      # what the merge above produces as garbage. This call does NOT
      # (and structurally CANNOT — there is no such field any more)
      # touch anything resembling a pin.
      {:ok, a_reopened} = Issue.update(ctx.root, a.id, %{status: "in_progress"}, ctx.store)
      assert a_reopened.status == "in_progress"

      assert {:violation, details} = Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)
      assert details.issue_id == a.id
      assert %{pinned: "closed", current: "in_progress"} = details.fields[:status]
      refute Map.has_key?(details.fields, :done_when)
      refute Map.has_key?(details.fields, :done_witness)

      # Demonstrate the point directly: nothing writable on the
      # current doc state can silence the verdict, because the
      # verdict never reads current doc state for the comparand — it
      # reads history. Even a write that ALSO forges plausible-looking
      # "done_*" fields on the current doc changes nothing, because
      # `done_when`/`done_witness` are compared against the STAMPED
      # commit's recorded values, not against whatever the current doc
      # claims.
      {:ok, a_forged} =
        Issue.update(
          ctx.root,
          a.id,
          %{done_when: "manual", done_witness: [], status: "in_progress"},
          ctx.store
        )

      assert a_forged.status == "in_progress"

      assert {:violation, details2} = Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)
      assert details2.issue_id == a.id
      assert %{pinned: "closed", current: "in_progress"} = details2.fields[:status]
    end
  end

  test "the false-alarm guard: a legal post-close edit (title, labels) does NOT trip the invariant",
       ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, _a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)
    assert :ok == Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)

    # `title` and `labels` are NOT in WriteGuard's frozen set
    # (status/done_when/done_witness) — editing them post-close is
    # legal today, and the invariant must not fire on legal behaviour.
    {:ok, a_edited} =
      Issue.update(ctx.root, a.id, %{title: "A, renamed", labels: ["retro"]}, ctx.store)

    assert a_edited.title == "A, renamed"
    assert a_edited.labels == ["retro"]
    assert a_edited.status == "closed"

    assert :ok == Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)
  end

  test "a closed ticket with NO stamped close in history (pre-existing data, closed before CX-gvbf shipped, or closed by a path that never called Issue.close/4) -> :ok",
       ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

    # Deliberately bypass Issue.close/4 (the only writer of the
    # commit-metadata stamp) to simulate a ticket that closed before
    # the gate existed: a direct status write, no stamped commit ever
    # produced.
    {:ok, a_closed_no_pin} =
      Issue.update(ctx.root, a.id, %{status: "closed", closed_at: "irrelevant"}, ctx.store)

    assert a_closed_no_pin.status == "closed"

    assert :ok == Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)
  end

  test "an open (never-closed) issue -> :ok", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    assert a.status == "open"
    assert :ok == Invariants.closed_matches_pin(ctx.root, a.id, ctx.store)
  end
end
