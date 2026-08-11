defmodule Commonplace.Bd.TicketVerbsTest do
  @moduledoc """
  Slice S1 Part 4 — the `ticket_add_needs` / `ticket_update`
  `ViewActionDispatch` verbs that exercise `Commonplace.Bd.WriteGuard`.

  Fixture setup mirrors `Commonplace.PrRefreshPreviewTest` — the
  dispatcher's handlers talk to the default-named `CommitStore` via
  `CommitStoreClient`, so this needs the same "root pointer file +
  running default CommitStore" fixture, not a custom-named store the
  dispatcher singleton can't see.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Issue
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ticket_verbs_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      restored_data_dir = prior_data_dir || "tmp/test_data"
      Application.put_env(:commonplace, :data_dir, restored_data_dir)
      File.rm_rf!(dir)

      {:ok, restored_pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: restored_data_dir})

      assert Process.alive?(restored_pid)
      assert Process.whereis(Commonplace.Store.CommitStore) == restored_pid

      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.join(restored_data_dir, "commits")
    end)

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "test-ticket-verb-invoker",
      private_key: priv,
      public_key: pub
    }

    %{root: root_uuid, signing_context: signing_context}
  end

  defp create_ticket(root_uuid, title) do
    {:ok, issue, _dir} = Issue.create(root_uuid, %{title: title})
    issue
  end

  describe "ticket_add_needs" do
    test "adds a well-formed local prereq ref", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")
      b = create_ticket(root, "B")

      context = %{
        args: %{"ticket" => a.id, "needs_ticket" => b.id},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("ticket_add_needs", context)

      assert details.action == "ticket_add_needs"
      assert details.needs == [%{"ticket" => b.id}]

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.needs == [%{"ticket" => b.id}]
    end

    test "refuses a cycle: A needs B, then B needs A", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")
      b = create_ticket(root, "B")

      {:ok, :tree_mutation, _} =
        ViewActionDispatch.dispatch("ticket_add_needs", %{
          args: %{"ticket" => a.id, "needs_ticket" => b.id},
          signing_context: ctx,
          source: "test"
        })

      assert {:error, reason} =
               ViewActionDispatch.dispatch("ticket_add_needs", %{
                 args: %{"ticket" => b.id, "needs_ticket" => a.id},
                 signing_context: ctx,
                 source: "test"
               })

      assert reason =~ "cycle"

      {:ok, b_reloaded} = Issue.show(root, b.id)
      assert b_reloaded.needs == []
    end

    test "accepts a cross-repo-leaf prereq without walking it", %{
      root: root,
      signing_context: ctx
    } do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "needs_ticket" => a.id, "needs_repo" => "other-repo-root"},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, _details} =
               ViewActionDispatch.dispatch("ticket_add_needs", context)

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.needs == [%{"ticket" => a.id, "repo" => "other-repo-root"}]
    end

    test "unknown ticket is refused", %{root: _root, signing_context: ctx} do
      context = %{
        args: %{"ticket" => "CX-nope", "needs_ticket" => "CX-alsono"},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, _reason} = ViewActionDispatch.dispatch("ticket_add_needs", context)
    end
  end

  describe "ticket_update" do
    test "refuses description instead of silently dropping it", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => ticket.id, "changes" => %{"description" => "x"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "description"
      assert reason =~ "Bd.Issue.write_description/5"
      assert {:ok, ""} = Issue.description(root, ticket.id)
    end

    test "refuses a mixed valid and unknown change without applying either", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, "original")

      context = %{
        args: %{
          "ticket" => ticket.id,
          "changes" => %{"title" => "renamed", "description" => "x", "mystery" => true}
        },
        signing_context: ctx,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "description"
      assert reason =~ "mystery"
      assert reason =~ "Updatable fields: title, priority"

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.title == "original"
      assert {:ok, ""} = Issue.description(root, ticket.id)
    end

    test "refuses a change touching status", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"status" => "closed"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "status"
      assert reason =~ "ticket_close"

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.status == "open"
    end

    test "refuses a change touching done_witness", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"done_witness" => ["deadbeef"]}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, _reason} = ViewActionDispatch.dispatch("ticket_update", context)
    end

    test "refuses a change touching claimed_by", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"claimed_by" => "id@pub"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, _reason} = ViewActionDispatch.dispatch("ticket_update", context)
    end

    test "succeeds for title/priority changes", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"title" => "renamed", "priority" => "p0"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("ticket_update", context)

      assert details.action == "ticket_update"

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.title == "renamed"
      assert reloaded.priority == "p0"
    end
  end
end
