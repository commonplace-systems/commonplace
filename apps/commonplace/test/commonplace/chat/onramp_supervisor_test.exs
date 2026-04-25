defmodule Commonplace.Chat.OnrampSupervisorTest do
  @moduledoc """
  CX-9zpb (R1 of CX-p2qp): per-room red-onramp supervision.

  OnrampSupervisor is a DynamicSupervisor that owns one RedLog
  magenta→red onramp per chat room. Per chat-room.md (a5f3f5e on
  commonplace-plan/main): rooms get an onramp at first activity (lazy
  per discussion in msg #3042); ensure_started/2 is idempotent so
  concurrent first-actions for the same room dedup.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.OnrampSupervisor
  alias Commonplace.Dataflow.{Magenta, RedLog}
  alias Commonplace.Store.CommitStore

  setup do
    # The OnrampSupervisor is part of Application.start. Tests share it
    # with the running tree (so PubSub + Magenta routing stays intact)
    # and use OnrampSupervisor.reset/0 to wipe per-test state.
    OnrampSupervisor.reset()

    dir = Path.join(System.tmp_dir!(), "cp_chat_onramp_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"chat_onramp_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    on_exit(fn ->
      OnrampSupervisor.reset()
      File.rm_rf!(dir)
    end)

    %{store: store_name, dir: dir}
  end

  describe "ensure_started/3" do
    test "starts a RedLog onramp for the room and returns its pid", %{store: store} do
      log_uuid = UUID.uuid4()

      assert {:ok, pid} = OnrampSupervisor.ensure_started("general", log_uuid, store: store)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "is idempotent: second call returns the same pid", %{store: store} do
      log_uuid = UUID.uuid4()

      assert {:ok, pid_a} = OnrampSupervisor.ensure_started("general", log_uuid, store: store)
      assert {:ok, pid_b} = OnrampSupervisor.ensure_started("general", log_uuid, store: store)
      assert pid_a == pid_b
    end

    test "different rooms get different onramps", %{store: store} do
      {:ok, pid_a} = OnrampSupervisor.ensure_started("general", UUID.uuid4(), store: store)
      {:ok, pid_b} = OnrampSupervisor.ensure_started("loom", UUID.uuid4(), store: store)

      refute pid_a == pid_b
    end
  end

  describe "stop/1" do
    test "terminates the onramp for the named room", %{store: store} do
      {:ok, pid} = OnrampSupervisor.ensure_started("ephemeral", UUID.uuid4(), store: store)
      assert Process.alive?(pid)

      assert :ok = OnrampSupervisor.stop("ephemeral")
      refute Process.alive?(pid)
    end

    test "stop on an unknown room is a harmless no-op" do
      assert :ok = OnrampSupervisor.stop("never-started")
    end
  end

  describe "end-to-end magenta → onramp → red log" do
    test "broadcasts on chat:{room}:events land in the room's red log", %{store: store} do
      log_uuid = UUID.uuid4()
      {:ok, _pid} = OnrampSupervisor.ensure_started("general", log_uuid, store: store)

      msg = Magenta.message("post", "chat", %{"text" => "hello red"})
      Magenta.send("chat:general:events", msg)

      # The onramp debounces commits (RedLog @auto_commit_debounce_ms = 250ms),
      # so we wait past the debounce window before reading.
      Process.sleep(400)

      log = RedLog.load(log_uuid, store)
      events = RedLog.read(log)

      assert Enum.any?(events, fn e ->
               e["type"] == "post" and get_in(e, ["payload", "text"]) == "hello red"
             end),
             "magenta event must land in the red log via the onramp"
    end
  end
end
