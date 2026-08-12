defmodule Commonplace.Bd.TicketCreateDeadlineTest do
  @moduledoc """
  CX-gc7q: end-to-end deadline coverage for the ticket-create chain,
  including the red-first reproduction of defect CX-0mns.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Issue, Workspace}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.ViewActionDispatch

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:commonplace)
    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "cx_gc7q_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    store = :"cx_gc7q_store_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    workspace = Commonplace.Test.WorkspaceFixture.complete_workspace!(dir, store: store)
    {:ok, _meta} = Workspace.load_meta(workspace.root_uuid, store)

    %{dir: dir, root: workspace.root_uuid, store: store}
  end

  test "CX-0mns reproduction: a generous outer deadline survives more than the old inner five seconds",
       ctx do
    store_pid = Process.whereis(ctx.store)
    :ok = :sys.suspend(store_pid)

    task =
      Task.async(fn ->
        ViewActionDispatch.dispatch("ticket_create", %{
          args: %{"title" => "slow but bounded"},
          root_uuid: ctx.root,
          store: ctx.store,
          ticket_create_deadline: System.monotonic_time(:millisecond) + 30_000,
          source: "test"
        })
      end)

    receive do
    after
      5_100 -> :ok
    end

    :ok = :sys.resume(store_pid)

    assert {:ok, :tree_mutation, details} = Task.await(task, 30_000)
    assert {:ok, issue} = Issue.show(ctx.root, details.ticket, ctx.store)
    assert issue.id == details.ticket
  end

  test "refuses below the measured floor before mint and leaves no id in store or index", ctx do
    before = store_fingerprint(ctx.store)
    floor = ViewActionDispatch.ticket_create_floor_ms()

    assert {:error, reason} =
             ViewActionDispatch.dispatch("ticket_create", %{
               args: %{"title" => "too little budget"},
               root_uuid: ctx.root,
               store: ctx.store,
               ticket_create_deadline: System.monotonic_time(:millisecond) + floor - 1,
               source: "test"
             })

    assert reason =~ "insufficient remaining budget for create:"
    assert reason =~ "< floor #{floor}"
    assert store_fingerprint(ctx.store) == before
    assert Commonplace.Bd.IssueDocIndex.entries(ctx.store) == before.issue_doc_entries
  end

  test "burned upstream time reaches the first seam as remaining time and names expiry", ctx do
    before = store_fingerprint(ctx.store)
    floor = ViewActionDispatch.ticket_create_floor_ms()
    original_budget = floor + 400
    deadline = System.monotonic_time(:millisecond) + original_budget

    receive do
    after
      250 -> :ok
    end

    store_pid = Process.whereis(ctx.store)
    :ok = :sys.suspend(store_pid)
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        ViewActionDispatch.dispatch("ticket_create", %{
          args: %{"title" => "remaining not original"},
          root_uuid: ctx.root,
          store: ctx.store,
          ticket_create_deadline: deadline,
          source: "test"
        })
      end)

    assert {:error, "deadline exhausted at put_built_commit(issue doc)"} =
             Task.await(task, original_budget + 1_000)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < original_budget - 100

    :ok = :sys.resume(store_pid)
    _ = :sys.get_state(store_pid)

    assert store_fingerprint(ctx.store) == before
    assert Commonplace.Bd.IssueDocIndex.entries(ctx.store) == before.issue_doc_entries
  end

  test "absent deadline preserves direct create and the exact legacy seam request", ctx do
    assert {:ok, issue, _dir} =
             Issue.create(ctx.root, %{title: "deadline-absent compatibility"}, ctx.store, [])

    assert {:ok, stored} = Issue.show(ctx.root, issue.id, ctx.store)
    assert stored == issue

    test_pid = self()
    commit = Commonplace.Store.Commit.genesis(UUID.uuid4())

    probe =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:"$gen_call", from, request} ->
               send(test_pid, {:legacy_request, request})
               GenServer.reply(from, {:ok, commit})
           end
         end}
      )

    assert {:ok, ^commit} = CommitStore.put_built_commit(probe, commit, nil, nil)
    assert_receive {:legacy_request, {:put_built_commit, ^commit, nil, nil}}
  end

  defp store_fingerprint(store) do
    doc_uuids = CommitStoreClient.all_doc_uuids(store)

    %{
      doc_uuids: doc_uuids,
      commit_ids: Map.new(doc_uuids, &{&1, CommitStoreClient.commit_ids_for_doc(store, &1)}),
      issue_doc_entries: Commonplace.Bd.IssueDocIndex.entries(store)
    }
  end
end
