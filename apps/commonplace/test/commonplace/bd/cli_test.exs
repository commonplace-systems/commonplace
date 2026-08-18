defmodule Commonplace.Bd.CLITest do
  @moduledoc """
  Bd P2 — thin CLI/query layer over the ticket-DAG (CX-1duj).

  Fixture setup mirrors `Commonplace.Bd.ClaimTest` / `CloseGateTest` —
  the dispatcher's verbs talk to the default-named `CommitStore` via
  `CommitStoreClient`, so this needs the "root pointer file + running
  default CommitStore" fixture; claim/eligible tests additionally need
  a Bursar started under its default name.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{CLI, Issue}
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Green.Bursar
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_cli_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Commonplace.Tree.Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

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

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "cli-test-invoker",
      private_key: priv,
      public_key: pub
    }

    %{root: root_uuid, signing_context: signing_context}
  end

  defp create_ticket(root_uuid, attrs) do
    {:ok, issue, _dir} = Issue.create(root_uuid, attrs)
    issue
  end

  describe "ready/2" do
    test "returns ready tickets in priority order (p0 before p2), excludes blocked", %{
      root: root
    } do
      p2 = create_ticket(root, %{title: "low priority ready", priority: "p2"})
      p0 = create_ticket(root, %{title: "high priority ready", priority: "p0"})

      blocker = create_ticket(root, %{title: "unmet need", priority: "p1"})

      _blocked =
        create_ticket(root, %{
          title: "blocked ticket",
          priority: "p0",
          needs: [%{"ticket" => blocker.id}]
        })

      rows = CLI.ready(root)
      ids = Enum.map(rows, & &1.id)

      assert ids == [p0.id, blocker.id, p2.id]
    end
  end

  describe "blocked/2" do
    test "returns only the blocked ticket", %{root: root} do
      blocker = create_ticket(root, %{title: "unmet need"})

      blocked =
        create_ticket(root, %{
          title: "blocked ticket",
          needs: [%{"ticket" => blocker.id}]
        })

      rows = CLI.blocked(root)
      ids = Enum.map(rows, & &1.id)

      assert ids == [blocked.id]
    end
  end

  describe "eligible/2" do
    test "excludes a claimed ticket, includes it again after release", %{
      root: root,
      signing_context: sc
    } do
      a = create_ticket(root, %{title: "ready-a", priority: "p1"})
      b = create_ticket(root, %{title: "ready-b", priority: "p1"})

      eligible_ids = CLI.eligible(root) |> Enum.map(& &1.id)
      assert a.id in eligible_ids
      assert b.id in eligible_ids

      assert {:ok, _claimed_by} = CLI.claim(root, a.id, sc)

      eligible_ids = CLI.eligible(root) |> Enum.map(& &1.id)
      refute a.id in eligible_ids
      assert b.id in eligible_ids

      ready_ids = CLI.ready(root) |> Enum.map(& &1.id)
      assert a.id in ready_ids
    end
  end

  describe "render/1" do
    test "produces aligned lines containing id, priority, title", %{root: root} do
      a = create_ticket(root, %{title: "fix the thing", priority: "p1", type: "bug"})

      rows = CLI.ready(root)
      text = CLI.render(rows)

      assert text =~ a.id
      assert text =~ "p1"
      assert text =~ "bug"
      assert text =~ "fix the thing"
    end
  end

  describe "claim/4" do
    test "claims a ready ticket, returns {:ok, claimed_by}", %{root: root, signing_context: sc} do
      ticket = create_ticket(root, %{title: "claimable"})

      assert {:ok, claimed_by} = CLI.claim(root, ticket.id, sc)
      assert is_binary(claimed_by)

      eligible_ids = CLI.eligible(root) |> Enum.map(& &1.id)
      refute ticket.id in eligible_ids
    end

    test "a second claim on the same ticket is refused", %{root: root, signing_context: sc} do
      {pub2, priv2} = Signing.generate_keypair()

      other_ctx = %SigningContext{
        identity_uuid: "cli-test-other",
        private_key: priv2,
        public_key: pub2
      }

      ticket = create_ticket(root, %{title: "contested"})

      assert {:ok, _} = CLI.claim(root, ticket.id, sc)
      assert {:error, _reason} = CLI.claim(root, ticket.id, other_ctx)
    end
  end

  describe "close/5" do
    test "closes a manual ticket, returns {:ok, \"closed\"}", %{
      root: root,
      signing_context: sc
    } do
      ticket = create_ticket(root, %{title: "manual close"})

      assert {:ok, "closed"} = CLI.close(root, ticket.id, [], sc)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "closed"
    end
  end
end
