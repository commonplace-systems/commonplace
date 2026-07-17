defmodule Commonplace.Scheduler.AgentTest do
  @moduledoc """
  CX-6av: userland scheduler agent. Mounts a CRDT doc under
  `__system/scheduler`, accepts magenta requests on `agents/scheduler`,
  persists schedules in the doc, fires magenta at the scheduled time.

  The doc is the source of truth. Restart / crash recovery uses only
  the doc — no side storage. Catch-up: pending entries whose fire_at
  has passed fire immediately on start.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Scheduler.{Agent, Doc}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{Schema, Walk}
  alias Yelixer.Encoding

  @inbox "agents/scheduler"

  setup do
    dir = Path.join(System.tmp_dir!(), "sched_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"sched_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Every agent needs a workspace root to mount under.
    root_uuid = "sched-root-#{:rand.uniform(1_000_000)}"
    root = Schema.new_schema()
    CommitStore.create_commit(name, root_uuid, Encoding.encode_update(root), nil)

    %{store: name, root: root_uuid}
  end

  defp start_agent(store, root, opts \\ []) do
    agent_name = :"sched_agent_#{:rand.uniform(1_000_000)}"

    {:ok, pid} =
      Agent.start_link(
        Keyword.merge(
          [store: store, root_uuid: root, name: agent_name],
          opts
        )
      )

    on_exit(fn ->
      if Process.alive?(pid), do: (try do GenServer.stop(pid) catch (:exit, _ -> :ok) end)
    end)

    {pid, agent_name}
  end

  defp schedule_loader(store) do
    fn uuid ->
      case CommitStore.latest_commit(store, uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema()
          {:ok, doc} = Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema()
      end
    end
  end

  defp resolve_scheduler_doc_uuid(store, root) do
    Walk.resolve_path(root, "__system/scheduler", schedule_loader(store))
  end

  describe "mount (lazy-create __system/scheduler)" do
    test "creates both __system dir and the scheduler doc entry on first start",
         %{store: store, root: root} do
      {:error, _} = resolve_scheduler_doc_uuid(store, root)
      start_agent(store, root)

      assert {:ok, scheduler_uuid} = resolve_scheduler_doc_uuid(store, root)
      assert is_binary(scheduler_uuid)
    end

    test "second start reuses the existing __system/scheduler doc (no duplicates)",
         %{store: store, root: root} do
      {pid, _} = start_agent(store, root)
      {:ok, first_uuid} = resolve_scheduler_doc_uuid(store, root)
      GenServer.stop(pid)

      {_pid2, _} = start_agent(store, root)
      {:ok, second_uuid} = resolve_scheduler_doc_uuid(store, root)

      assert first_uuid == second_uuid
    end
  end

  describe "schedule magenta verb" do
    test "writes a pending entry to the scheduler doc and replies with scheduled",
         %{store: store, root: root} do
      {_pid, _} = start_agent(store, root)
      Magenta.subscribe(@inbox)

      fire_at = iso_in_future(5_000)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "fire_at" => fire_at,
          "target_topic" => "jobs/done",
          "payload" => %{"kind" => "build"}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"} = reply}, 2000
      assert is_binary(reply.payload["id"])
      id = reply.payload["id"]

      {:ok, scheduler_uuid} = resolve_scheduler_doc_uuid(store, root)
      sdoc = Doc.load(scheduler_uuid, store)
      assert {:ok, entry} = Doc.get(sdoc, id)
      assert entry["status"] == "pending"
      assert entry["target_topic"] == "jobs/done"
      assert entry["fire_at"] == fire_at
    end

    test "caller-supplied id is honored", %{store: store, root: root} do
      {_pid, _} = start_agent(store, root)
      Magenta.subscribe(@inbox)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "id" => "my-explicit-id",
          "fire_at" => iso_in_future(5_000),
          "target_topic" => "t",
          "payload" => %{}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"} = reply}, 2000
      assert reply.payload["id"] == "my-explicit-id"
    end
  end

  describe "fire" do
    test "publishes magenta on target_topic when fire_at is reached",
         %{store: store, root: root} do
      {_pid, _} = start_agent(store, root)
      target = "jobs/done-#{:rand.uniform(1_000_000)}"
      Magenta.subscribe(target)
      Magenta.subscribe(@inbox)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "fire_at" => iso_in_future(100),
          "target_topic" => target,
          "payload" => %{"hi" => "there"}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"} = reply}, 2000
      id = reply.payload["id"]

      assert_receive {:magenta, ^target, %Magenta{type: "fire"} = fired}, 2000
      assert fired.payload["id"] == id
      assert fired.payload["hi"] == "there"
    end

    test "flips status to fired in the doc after firing",
         %{store: store, root: root} do
      {_pid, _} = start_agent(store, root)
      target = "jobs/flip-#{:rand.uniform(1_000_000)}"
      Magenta.subscribe(target)
      Magenta.subscribe(@inbox)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "fire_at" => iso_in_future(100),
          "target_topic" => target,
          "payload" => %{}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"} = reply}, 2000
      id = reply.payload["id"]
      assert_receive {:magenta, ^target, %Magenta{type: "fire"}}, 2000

      # Poll briefly — commit happens after broadcast.
      {:ok, scheduler_uuid} = resolve_scheduler_doc_uuid(store, root)
      eventually(fn ->
        sdoc = Doc.load(scheduler_uuid, store)
        {:ok, entry} = Doc.get(sdoc, id)
        assert entry["status"] == "fired"
      end)
    end
  end

  describe "cancel" do
    test "flips status to cancelled and prevents the fire",
         %{store: store, root: root} do
      {_pid, _} = start_agent(store, root)
      target = "jobs/cancel-#{:rand.uniform(1_000_000)}"
      Magenta.subscribe(target)
      Magenta.subscribe(@inbox)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "fire_at" => iso_in_future(5_000),
          "target_topic" => target,
          "payload" => %{}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"} = reply}, 2000
      id = reply.payload["id"]

      Magenta.send(@inbox, Magenta.message("cancel", "test", %{"id" => id}))
      assert_receive {:magenta, @inbox, %Magenta{type: "cancelled"} = canc}, 2000
      assert canc.payload["id"] == id

      {:ok, scheduler_uuid} = resolve_scheduler_doc_uuid(store, root)
      sdoc = Doc.load(scheduler_uuid, store)
      assert {:ok, %{"status" => "cancelled"}} = Doc.get(sdoc, id)

      # Ensure fire does NOT happen even after fire_at would have passed.
      refute_receive {:magenta, ^target, %Magenta{type: "fire"}}, 400
    end

    test "cancelling unknown id replies with not_found", %{store: store, root: root} do
      {_pid, _} = start_agent(store, root)
      Magenta.subscribe(@inbox)

      Magenta.send(@inbox, Magenta.message("cancel", "test", %{"id" => "ghost"}))
      assert_receive {:magenta, @inbox, %Magenta{type: "not_found"} = reply}, 2000
      assert reply.payload["id"] == "ghost"
    end
  end

  describe "list" do
    test "replies with every schedule entry", %{store: store, root: root} do
      {_pid, _} = start_agent(store, root)
      Magenta.subscribe(@inbox)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "id" => "a",
          "fire_at" => iso_in_future(10_000),
          "target_topic" => "t",
          "payload" => %{}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"}}, 2000

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "id" => "b",
          "fire_at" => iso_in_future(11_000),
          "target_topic" => "t",
          "payload" => %{}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"}}, 2000

      Magenta.send(@inbox, Magenta.message("list", "test", %{}))
      assert_receive {:magenta, @inbox, %Magenta{type: "listed"} = reply}, 2000

      ids = reply.payload["schedules"] |> Enum.map(& &1["id"]) |> MapSet.new()
      assert MapSet.member?(ids, "a")
      assert MapSet.member?(ids, "b")
    end
  end

  describe "catch-up on startup" do
    test "fires past-due pending entries immediately after start",
         %{store: store, root: root} do
      # Seed a scheduler doc by running the agent briefly, scheduling one
      # entry with a fire_at still in the future, then stopping.
      {pid1, _} = start_agent(store, root)
      target = "jobs/catchup-#{:rand.uniform(1_000_000)}"
      Magenta.subscribe(@inbox)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "fire_at" => iso_in_future(60_000),
          "target_topic" => target,
          "payload" => %{"late" => true}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"} = reply}, 2000
      id = reply.payload["id"]
      GenServer.stop(pid1)

      # Rewrite the doc to move fire_at into the past — simulates time
      # having elapsed while the agent was offline.
      {:ok, scheduler_uuid} = resolve_scheduler_doc_uuid(store, root)
      sdoc = Doc.load(scheduler_uuid, store)
      {:ok, entry} = Doc.get(sdoc, id)
      past_entry = Map.put(entry, "fire_at", iso_in_past(5_000))
      sdoc = Doc.put(sdoc, id, past_entry)

      {:ok, _persisted} =
        CommitStore.create_chained_commit(
          store,
          scheduler_uuid,
          Encoding.encode_update(sdoc)
        )
        |> then(fn commit -> {:ok, commit} end)

      # Subscribe to the target BEFORE the new agent starts so the
      # immediate catch-up fire is observable.
      Magenta.subscribe(target)

      {_pid2, _} = start_agent(store, root)

      assert_receive {:magenta, ^target, %Magenta{type: "fire"} = fired}, 2000
      assert fired.payload["id"] == id
      assert fired.payload["late"] == true
    end

    test "ignores cancelled entries at catch-up (no spurious fire)",
         %{store: store, root: root} do
      {pid1, _} = start_agent(store, root)
      target = "jobs/nofire-#{:rand.uniform(1_000_000)}"
      Magenta.subscribe(@inbox)

      Magenta.send(
        @inbox,
        Magenta.message("schedule", "test", %{
          "fire_at" => iso_in_future(60_000),
          "target_topic" => target,
          "payload" => %{}
        })
      )

      assert_receive {:magenta, @inbox, %Magenta{type: "scheduled"} = reply}, 2000
      id = reply.payload["id"]

      Magenta.send(@inbox, Magenta.message("cancel", "test", %{"id" => id}))
      assert_receive {:magenta, @inbox, %Magenta{type: "cancelled"}}, 2000
      GenServer.stop(pid1)

      Magenta.subscribe(target)
      {_pid2, _} = start_agent(store, root)

      refute_receive {:magenta, ^target, %Magenta{type: "fire"}}, 400
    end
  end

  # --- helpers ---

  defp iso_in_future(ms) do
    DateTime.utc_now()
    |> DateTime.add(ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp iso_in_past(ms) do
    DateTime.utc_now()
    |> DateTime.add(-ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp eventually(fun, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    try do
      fun.()
    rescue
      e ->
        if System.monotonic_time(:millisecond) >= deadline do
          reraise e, __STACKTRACE__
        else
          Process.sleep(25)
          do_eventually(fun, deadline)
        end
    end
  end
end
