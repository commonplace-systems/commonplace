defmodule Commonplace.CLI.BdCmdTest do
  @moduledoc """
  CX-hrbn — the two dispositions `commonplace bd` got at the
  tix-authority cutover (2026-08-05).

  `bd ready` / `bd blocked` were REPOINTED: they used to walk the
  `blocks` edges in `/bd/deps.json`, which nothing writes any more, and
  now serve the live `needs` graph through the same Frontier-backed
  path as `Commonplace.Bd.CLI`.

  `bd dep add|remove|list` and `bd import deps` were RETIRED: they only
  ever touched the frozen graph, so they print the retirement notice
  and report failure.

  The two halves are one test file on purpose — the repointed verbs
  prove the live graph is reachable, which is what makes the refusals
  a redirection rather than a dead end.
  """
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Commonplace.Bd.Issue
  alias Commonplace.CLI.Bd, as: BdCmd
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cli_bd_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_cli_bd_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "cli-status-test",
      private_key: priv,
      public_key: pub
    }

    %{store: store, root: root, signing_context: signing_context}
  end

  describe "bd update --status uses the decision table" do
    test "the former permissive arm refuses in_progress and records an allowed decision", ctx do
      {:ok, ticket, _} = Issue.create(ctx.root, %{title: "CLI status"}, ctx.store)

      assert {:error, refusal} =
               BdCmd.update_ticket(
                 ctx.root,
                 ticket.id,
                 %{status: "in_progress"},
                 "legacy CLI attempt",
                 ctx.signing_context,
                 ctx.store
               )

      assert refusal ==
               "ticket_set_status refuses transition from \"open\" to \"in_progress\": " <>
                 "in_progress is EXIT-ONLY and has no inbound edges; custody is represented by the claim token; " <>
                 "legal targets from open: open, blocked, review, wontfix"

      {:ok, unchanged} = Issue.show(ctx.root, ticket.id, ctx.store)
      assert unchanged.status == "open"

      assert {:ok, reviewed} =
               BdCmd.update_ticket(
                 ctx.root,
                 ticket.id,
                 %{status: "review"},
                 "ready for review",
                 ctx.signing_context,
                 ctx.store
               )

      assert reviewed.status == "review"
      assert List.last(reviewed.extra["status_decisions"])["reason"] == "ready for review"
    end
  end

  describe "bd ready / bd blocked serve the live needs graph" do
    test "a ticket with an open prerequisite is blocked, its prereq is ready", ctx do
      {:ok, prereq, _} = Issue.create(ctx.root, %{title: "lay the cable"}, ctx.store)

      {:ok, dependent, _} =
        Issue.create(
          ctx.root,
          %{title: "light the cable", needs: [%{"ticket" => prereq.id}]},
          ctx.store
        )

      ready = capture_io(fn -> BdCmd.cmd_ready(ctx.root, ctx.store) end)
      blocked = capture_io(fn -> BdCmd.cmd_blocked(ctx.root, ctx.store) end)

      assert ready =~ prereq.id
      refute ready =~ dependent.id

      assert blocked =~ dependent.id
      refute blocked =~ prereq.id
    end

    test "closing the prerequisite moves the dependent into ready", ctx do
      {:ok, prereq, _} = Issue.create(ctx.root, %{title: "prereq"}, ctx.store)

      {:ok, dependent, _} =
        Issue.create(
          ctx.root,
          %{title: "dependent", needs: [%{"ticket" => prereq.id}]},
          ctx.store
        )

      {:ok, _} = Issue.update(ctx.root, prereq.id, %{status: "closed"}, ctx.store)

      ready = capture_io(fn -> BdCmd.cmd_ready(ctx.root, ctx.store) end)
      assert ready =~ dependent.id
    end

    # The semantics change is the POINT of the repoint, so pin it
    # rather than leaving it implied: under the retired `blocks` walk
    # this ticket was ready (no incoming edge => go). Under `needs` an
    # unresolvable prerequisite is unsatisfied, so it is blocked.
    test "an unresolvable prerequisite blocks — the needs-graph semantics, not the old blocks-graph ones",
         ctx do
      {:ok, t, _} =
        Issue.create(
          ctx.root,
          %{title: "waits on a ghost", needs: [%{"ticket" => "CX-doesnotexist"}]},
          ctx.store
        )

      refute capture_io(fn -> BdCmd.cmd_ready(ctx.root, ctx.store) end) =~ t.id
      assert capture_io(fn -> BdCmd.cmd_blocked(ctx.root, ctx.store) end) =~ t.id
    end

    test "an empty frontier says so rather than printing nothing", ctx do
      assert capture_io(fn -> BdCmd.cmd_blocked(ctx.root, ctx.store) end) =~ "(no tickets)"
    end
  end

  describe "bd dep verbs refuse loudly" do
    test "dep list prints the notice, names the replacement, and reports failure", ctx do
      {result, out} = with_stderr(fn -> BdCmd.cmd_dep_list(ctx.root, ctx.store) end)

      assert result == :retired
      assert_notice(out)
    end

    test "dep add prints the notice and points at the gated verb", ctx do
      {result, out} =
        with_stderr(fn -> BdCmd.cmd_dep_add(ctx.root, "CX-a", "CX-b", [], ctx.store) end)

      assert result == :retired
      assert_notice(out)
      assert out =~ "ticket_add_needs"
    end

    test "dep remove prints the notice", ctx do
      {result, out} =
        with_stderr(fn -> BdCmd.cmd_dep_remove(ctx.root, "CX-a", "CX-b", [], ctx.store) end)

      assert result == :retired
      assert_notice(out)
    end

    test "import deps prints the notice and points at import issues", ctx do
      path = Path.join(System.tmp_dir!(), "cp_cli_bd_deps_#{:rand.uniform(1_000_000)}.jsonl")
      File.write!(path, ~s({"from":"CX-a","to":"CX-b","kind":"blocks"}\n))
      on_exit(fn -> File.rm_rf!(path) end)

      {result, out} = with_stderr(fn -> BdCmd.cmd_import_deps(ctx.root, path, ctx.store) end)

      assert result == :retired
      assert_notice(out)
      assert out =~ "import_issues_jsonl/4"
    end

    # The control: a refusal that printed nothing, or printed to stdout
    # while exiting 0, would read as "no edges" to a human and as
    # success to a script. Both failure modes are the frozen-graph
    # misreport wearing a different hat.
    test "the notice never reads as an empty graph", ctx do
      {_result, out} = with_stderr(fn -> BdCmd.cmd_dep_list(ctx.root, ctx.store) end)

      refute out == ""
      refute out =~ "(no "
    end
  end

  defp assert_notice(out) do
    assert out =~ "RETIRED"
    assert out =~ "2026-08-05"
    assert out =~ "/bd/deps.json"
    assert out =~ "needs"
  end

  # `capture_io/2` on :stderr returns the captured text, not the
  # function's value; we need both, so stash the value on the way past.
  defp with_stderr(fun) do
    ref = make_ref()
    parent = self()

    out = capture_io(:stderr, fn -> send(parent, {ref, fun.()}) end)
    assert_receive {^ref, result}
    {result, out}
  end
end
