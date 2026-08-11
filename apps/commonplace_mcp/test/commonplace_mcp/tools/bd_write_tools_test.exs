defmodule Commonplace.MCP.Tools.BdWriteToolsTest do
  @moduledoc """
  Tier-2 WRITE MCP tools over the ticket-DAG (bd_create / bd_add_needs /
  bd_update / bd_close / bd_claim / bd_release) plus the BdWrite
  signing-context helper.

  Because `CommitStoreClient.remote_node/0` defaults to `:local` (no
  serve node configured in test), `BdRoute.call` runs the target
  function LOCALLY — so this builds a real local bd workspace and
  asserts the tools mutate real data. Fixture mirrors
  `Commonplace.MCP.Tools.BdToolsTest` / `Commonplace.Bd.ClaimTest`.

  Writes are signed by a TEST key passed via the session context (the
  node key does not exist in the tmp data_dir). The default test store
  is permissive, so it accepts the signed write.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Issue
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Green.Bursar

  alias Commonplace.MCP.Tools.{
    BdAddNeeds,
    BdClaim,
    BdClose,
    BdCreate,
    BdRelease,
    BdUpdate
  }

  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient

  setup do
    CommitStoreClient.clear_remote_node()

    dir = Path.join(System.tmp_dir!(), "cp_bd_write_mcp_test_#{:rand.uniform(1_000_000_000)}")
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

    # A running default-named Bursar is needed only for claim/release
    # (custody token). Mirrors Commonplace.Bd.ClaimTest.
    case GenServer.whereis(Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: Commonplace.Store.CommitStore,
        sweep_interval: 60_000
      )

    on_exit(fn ->
      if Process.alive?(bursar_pid) do
        try do
          GenServer.stop(bursar_pid)
        catch
          :exit, _ -> :ok
        end
      end

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

      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.join(restored_data_dir, "commits")
    end)

    {pub, priv} = Signing.generate_keypair()
    sc = %SigningContext{identity_uuid: "test-bd-writer", private_key: priv, public_key: pub}

    %{root: root_uuid, sc: sc, ctx: %{signing_context: sc}}
  end

  defp create_ticket(root_uuid, attrs) do
    {:ok, issue, _dir} = Issue.create(root_uuid, attrs)
    issue
  end

  describe "bd_create" do
    test "creates a ticket that can be read back", %{root: root, ctx: ctx} do
      assert {:ok, result} = BdCreate.run(%{"title" => "created via mcp"}, ctx)
      refute result["isError"]

      [_text_block, json_block] = result["content"]
      fields = Jason.decode!(json_block["text"])
      id = fields["id"]
      assert is_binary(id)
      assert fields["title"] == "created via mcp"
      assert fields["status"] == "open"
      assert fields["done_when"] == "manual"

      {:ok, issue} = Issue.show(root, id, CommitStoreClient)
      assert issue.title == "created via mcp"
      assert issue.status == "open"
    end

    test "honors type + priority + description", %{root: root, ctx: ctx} do
      assert {:ok, result} =
               BdCreate.run(
                 %{
                   "title" => "detailed",
                   "type" => "bug",
                   "priority" => "p0",
                   "description" => "the body"
                 },
                 ctx
               )

      fields = Jason.decode!(Enum.at(result["content"], 1)["text"])
      id = fields["id"]
      {:ok, issue} = Issue.show(root, id, CommitStoreClient)
      assert issue.type == "bug"
      assert issue.priority == "p0"
      {:ok, desc} = Issue.description(root, id, CommitStoreClient)
      assert desc == "the body"
    end

    test "missing title → invalid_params", %{ctx: ctx} do
      assert {:error, :invalid_params, msg} = BdCreate.run(%{}, ctx)
      assert msg =~ "title"
    end
  end

  describe "bd_add_needs" do
    test "adds an edge to the dependent's needs", %{root: root, ctx: ctx} do
      dependent = create_ticket(root, %{title: "dependent"})
      prereq = create_ticket(root, %{title: "prereq"})

      assert {:ok, result} =
               BdAddNeeds.run(
                 %{"ticket" => dependent.id, "needs_ticket" => prereq.id},
                 ctx
               )

      refute result["isError"]

      {:ok, reloaded} = Issue.show(root, dependent.id, CommitStoreClient)
      need_ids = Enum.map(reloaded.needs, fn ref -> ref["ticket"] || ref[:ticket] end)
      assert prereq.id in need_ids
    end

    test "a cycle-forming edge is refused with a clean error", %{root: root, ctx: ctx} do
      a = create_ticket(root, %{title: "cycle-a"})
      b = create_ticket(root, %{title: "cycle-b"})

      # A needs B (fine), then B needs A (would close a cycle).
      assert {:ok, _} = BdAddNeeds.run(%{"ticket" => a.id, "needs_ticket" => b.id}, ctx)

      assert {:error, :invalid_params, msg} =
               BdAddNeeds.run(%{"ticket" => b.id, "needs_ticket" => a.id}, ctx)

      assert is_binary(msg) and msg != ""
      refute msg =~ "{:"
    end

    test "missing needs_ticket → invalid_params", %{root: root, ctx: ctx} do
      t = create_ticket(root, %{title: "solo"})
      assert {:error, :invalid_params, msg} = BdAddNeeds.run(%{"ticket" => t.id}, ctx)
      assert msg =~ "needs_ticket"
    end
  end

  describe "bd_update" do
    test "changes a non-protected field", %{root: root, ctx: ctx} do
      t = create_ticket(root, %{title: "before", priority: "p2"})

      assert {:ok, result} =
               BdUpdate.run(%{"ticket" => t.id, "changes" => %{"priority" => "p0"}}, ctx)

      refute result["isError"]

      {:ok, reloaded} = Issue.show(root, t.id, CommitStoreClient)
      assert reloaded.priority == "p0"
    end

    test "surfaces a description refusal from ticket_update", %{root: root, ctx: ctx} do
      t = create_ticket(root, %{title: "before", description: "original body"})

      assert {:error, :invalid_params, msg} =
               BdUpdate.run(%{"ticket" => t.id, "changes" => %{"description" => "x"}}, ctx)

      assert msg =~ "description"
      assert msg =~ "Bd.Issue.write_description/5"
      assert {:ok, "original body"} = Issue.description(root, t.id, CommitStoreClient)
    end

    test "a protected field (status) is refused cleanly", %{root: root, ctx: ctx} do
      t = create_ticket(root, %{title: "guarded"})

      assert {:error, :invalid_params, msg} =
               BdUpdate.run(%{"ticket" => t.id, "changes" => %{"status" => "closed"}}, ctx)

      assert msg =~ "status"

      {:ok, reloaded} = Issue.show(root, t.id, CommitStoreClient)
      assert reloaded.status == "open"
    end

    test "missing changes → invalid_params", %{root: root, ctx: ctx} do
      t = create_ticket(root, %{title: "x"})
      assert {:error, :invalid_params, msg} = BdUpdate.run(%{"ticket" => t.id}, ctx)
      assert msg =~ "changes"
    end
  end

  describe "bd_close" do
    test "closes a manual-done_when ticket (no witness needed)", %{root: root, ctx: ctx} do
      t = create_ticket(root, %{title: "to close"})
      assert t.done_when == "manual"

      assert {:ok, result} = BdClose.run(%{"ticket" => t.id}, ctx)
      refute result["isError"]

      {:ok, reloaded} = Issue.show(root, t.id, CommitStoreClient)
      assert reloaded.status == "closed"
    end

    test "missing ticket → invalid_params", %{ctx: ctx} do
      assert {:error, :invalid_params, msg} = BdClose.run(%{}, ctx)
      assert msg =~ "ticket"
    end
  end

  describe "bd_claim / bd_release (Bursar-backed)" do
    test "claim then release round-trip", %{root: root, ctx: ctx} do
      t = create_ticket(root, %{title: "claimable"})

      assert {:ok, claim_result} = BdClaim.run(%{"ticket" => t.id}, ctx)
      refute claim_result["isError"]

      {:ok, claimed} = Issue.show(root, t.id, CommitStoreClient)
      refute is_nil(claimed.claimed_by)

      assert {:ok, release_result} = BdRelease.run(%{"ticket" => t.id}, ctx)
      refute release_result["isError"]

      {:ok, released} = Issue.show(root, t.id, CommitStoreClient)
      assert is_nil(released.claimed_by)
    end

    test "missing ticket → invalid_params", %{ctx: ctx} do
      assert {:error, :invalid_params, cmsg} = BdClaim.run(%{}, ctx)
      assert cmsg =~ "ticket"
      assert {:error, :invalid_params, rmsg} = BdRelease.run(%{}, ctx)
      assert rmsg =~ "ticket"
    end
  end
end
