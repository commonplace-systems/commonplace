defmodule Commonplace.MCP.Tools.BdToolsTest do
  @moduledoc """
  Tier-1 read-only MCP tools over the ticket-DAG (bd_ready / bd_blocked /
  bd_frontier / bd_show) plus the BdRoute routing helper.

  Because `CommitStoreClient.remote_node/0` defaults to `:local` (no
  serve node configured in test), `BdRoute.call` runs the target
  function LOCALLY — so this builds a real local bd workspace and
  asserts the tools return real data. Fixture mirrors
  `Commonplace.Bd.CLITest`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Issue
  alias Commonplace.MCP.Tools.{BdBlocked, BdFrontier, BdReady, BdRoute, BdShow}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient

  setup do
    # Guard against a leaked remote-node setting so BdRoute takes the
    # local (apply) path, not an rpc to a possibly-absent node.
    CommitStoreClient.clear_remote_node()

    dir = Path.join(System.tmp_dir!(), "cp_bd_mcp_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Commonplace.Tree.Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      CommitStoreClient.clear_remote_node()
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      restored_data_dir = prior_data_dir || "tmp/test_data"
      Application.put_env(:commonplace, :data_dir, restored_data_dir)
      File.rm_rf!(dir)

      {:ok, restored_pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: restored_data_dir})

      assert Process.alive?(restored_pid)
      assert Process.whereis(Commonplace.Store.CommitStore) == restored_pid

      # sol/s-snapshot-fresh-s3: the store expands its data_dir at init (the
      # relative-path/cwd-split fix), so assert the EXPANDED path — the intent
      # is "the restored singleton points at this store", not a string form.
      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.expand(Path.join(restored_data_dir, "commits"))
    end)

    %{root: root_uuid}
  end

  defp create_ticket(root_uuid, attrs) do
    {:ok, issue, _dir} = Issue.create(root_uuid, attrs)
    issue
  end

  describe "BdRoute.call/3" do
    test "runs the target function locally when no serve node is configured" do
      assert BdRoute.call(Kernel, :+, [1, 2]) == 3
      assert BdRoute.call(String, :upcase, ["hi"]) == "HI"
    end

    test "originates an absolute ticket-create deadline and leaves every other RPC unchanged" do
      context = %{args: %{"title" => "boundary"}, source: "test"}
      before_now = System.monotonic_time(:millisecond)

      assert ["ticket_create", deadline_context] =
               BdRoute.boundary_args(
                 Commonplace.ViewActionDispatch,
                 :dispatch,
                 ["ticket_create", context],
                 500
               )

      after_now = System.monotonic_time(:millisecond)
      deadline = deadline_context.ticket_create_deadline
      assert deadline >= before_now + 500
      assert deadline <= after_now + 500

      args = ["ticket_update", context]

      assert BdRoute.boundary_args(Commonplace.ViewActionDispatch, :dispatch, args, 500) == args
    end
  end

  describe "bd_ready" do
    test "returns open ready tickets in text + structured", %{root: root} do
      a = create_ticket(root, %{title: "first ready", priority: "p0", type: "bug"})
      b = create_ticket(root, %{title: "second ready", priority: "p2"})

      assert {:ok, result} = BdReady.run(%{})
      refute result["isError"]

      [text_block, json_block] = result["content"]
      text = text_block["text"]
      assert text =~ a.id
      assert text =~ "first ready"
      assert text =~ b.id
      assert text =~ "[p0/bug]"

      structured = Jason.decode!(json_block["text"])
      ids = Enum.map(structured["ready"], & &1["id"])
      assert a.id in ids
      assert b.id in ids

      row = Enum.find(structured["ready"], &(&1["id"] == a.id))
      assert row["priority"] == "p0"
      assert row["type"] == "bug"
      assert row["title"] == "first ready"
      assert row["status"] == "open"
      assert Map.has_key?(row, "claimed_by")
    end

    test "empty workspace yields a clean no-tickets summary", %{root: _root} do
      assert {:ok, result} = BdReady.run(%{})
      [text_block, json_block] = result["content"]
      assert text_block["text"] =~ "No ready tickets"
      assert Jason.decode!(json_block["text"])["ready"] == []
    end
  end

  describe "bd_blocked" do
    test "returns tickets with an unmet need", %{root: root} do
      blocker = create_ticket(root, %{title: "the blocker", priority: "p1"})

      blocked =
        create_ticket(root, %{
          title: "waiting on blocker",
          priority: "p1",
          needs: [%{"ticket" => blocker.id}]
        })

      assert {:ok, result} = BdBlocked.run(%{})
      [text_block, json_block] = result["content"]

      assert text_block["text"] =~ blocked.id
      structured = Jason.decode!(json_block["text"])
      ids = Enum.map(structured["blocked"], & &1["id"])
      assert blocked.id in ids
      refute blocker.id in ids
    end
  end

  describe "bd_frontier" do
    test "summarizes ready/blocked counts", %{root: root} do
      _ready = create_ticket(root, %{title: "ready one", priority: "p1"})
      blocker = create_ticket(root, %{title: "unmet", priority: "p1"})

      _blocked =
        create_ticket(root, %{
          title: "blocked one",
          priority: "p1",
          needs: [%{"ticket" => blocker.id}]
        })

      assert {:ok, result} = BdFrontier.run(%{})
      [text_block, json_block] = result["content"]

      structured = Jason.decode!(json_block["text"])
      # "ready one" + "unmet" are ready (unmet has no needs); "blocked one" is blocked.
      assert structured["ready_count"] == 2
      assert structured["blocked_count"] == 1
      assert is_list(structured["stranded"])

      assert text_block["text"] =~ "2 ready"
      assert text_block["text"] =~ "1 blocked"
    end
  end

  describe "bd_show" do
    test "returns issue fields + description for a real id", %{root: root} do
      {:ok, issue, _dir} =
        Issue.create(root, %{
          title: "detailed ticket",
          priority: "p1",
          type: "feature",
          description: "The full body of the ticket."
        })

      assert {:ok, result} = BdShow.run(%{"id" => issue.id})
      refute result["isError"]

      [text_block, json_block] = result["content"]
      text = text_block["text"]
      assert text =~ issue.id
      assert text =~ "detailed ticket"
      assert text =~ "The full body of the ticket."

      fields = Jason.decode!(json_block["text"])
      assert fields["id"] == issue.id
      assert fields["title"] == "detailed ticket"
      assert fields["priority"] == "p1"
      assert fields["type"] == "feature"
      assert fields["status"] == "open"
      assert fields["description"] == "The full body of the ticket."
      assert Map.has_key?(fields, "needs")
      assert Map.has_key?(fields, "labels")
      assert Map.has_key?(fields, "created_at")
    end

    test "a bogus id returns a clean not-found error", %{root: _root} do
      assert {:error, :invalid_params, msg} = BdShow.run(%{"id" => "CX-doesnotexist"})
      assert msg =~ "not found"
    end

    test "a missing id returns invalid_params", %{root: _root} do
      assert {:error, :invalid_params, msg} = BdShow.run(%{})
      assert msg =~ "id"
    end
  end
end
