defmodule Commonplace.Bots.WorkerOutcomeActivityTest do
  @moduledoc """
  CX-gptu: prove worker outcomes (end_turn / cap_hit / error)
  surface in __bot_activity with the right decision + reason.

  Drives Worker.run/4 with stub clients shaped to produce each
  outcome and asserts an activity entry appears for each.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Activity, Demo, Dispatcher, Entity}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_outcome_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    store_sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(store_sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(store_sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(store_sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    bots_sup = Commonplace.Bots.Supervisor

    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec({Commonplace.Bots.Dispatcher, [rate_limit_enabled: false]},
          id: Commonplace.Bots.Dispatcher
        )
      )

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, []},
            id: Commonplace.Bots.Dispatcher
          )
        )

      _ = Supervisor.terminate_child(store_sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(store_sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(
          store_sup,
          {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"}
        )

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_root do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp wait_for(fun, timeout_ms \\ 2_000, interval_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait = fn rec ->
      case fun.() do
        true ->
          :ok

        _ ->
          if System.monotonic_time(:millisecond) >= deadline do
            :timeout
          else
            Process.sleep(interval_ms)
            rec.(rec)
          end
      end
    end

    do_wait.(do_wait)
  end

  defp load_alice(demo) do
    {:ok, e} = Entity.load(CommitStoreClient, demo.bots["alice"], "alice.bot")
    e
  end

  defp setup_demo do
    root = mint_root()
    demo = Demo.bootstrap(root)
    :ok = Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)
    activity_uuid = Dispatcher.registered_rooms()[demo.room].activity_uuid
    {demo, activity_uuid}
  end

  defp find_outcome(activity_uuid, decision, opts) do
    bot = Keyword.get(opts, :bot)
    reason_match = Keyword.get(opts, :reason)

    Activity.list(activity_uuid, CommitStoreClient)
    |> Enum.find(fn e ->
      e["decision"] == decision and
        (bot == nil or e["bot"] == bot) and
        (reason_match == nil or e["reason"] == reason_match)
    end)
  end

  test "end_turn outcome → 'completed' activity entry" do
    {demo, activity_uuid} = setup_demo()
    alice = load_alice(demo)

    Commonplace.Bots.Worker.run("demo", alice, %{"message_id" => "m1", "text" => "hi"},
      client_fn: fn _ ->
        {:ok,
         %{
           "stop_reason" => "end_turn",
           "content" => [%{"type" => "text", "text" => "ok"}],
           "usage" => %{"output_tokens" => 5}
         }}
      end
    )

    assert wait_for(fn ->
             find_outcome(activity_uuid, "completed", bot: "alice") != nil
           end) == :ok
  end

  test "cap_hit outcome → 'cap_hit' activity entry with reason" do
    {demo, activity_uuid} = setup_demo()
    alice = load_alice(demo)

    tool_use = %{
      "stop_reason" => "tool_use",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "t1",
          "name" => "post_message",
          "input" => %{"text" => "x"}
        }
      ],
      "usage" => %{"output_tokens" => 10}
    }

    Commonplace.Bots.Worker.run("demo", alice, %{"message_id" => "m1", "text" => "spam"},
      client_fn: fn _ -> {:ok, tool_use} end,
      messages_uuid: demo.messages_uuid,
      max_calls: 1
    )

    assert wait_for(fn ->
             find_outcome(activity_uuid, "cap_hit", bot: "alice", reason: "calls") != nil
           end) == :ok
  end

  test "error outcome → 'error' activity entry with reason" do
    {demo, activity_uuid} = setup_demo()
    alice = load_alice(demo)

    Commonplace.Bots.Worker.run("demo", alice, %{"message_id" => "m1", "text" => "boom"},
      client_fn: fn _ -> {:error, :boom} end
    )

    assert wait_for(fn ->
             find_outcome(activity_uuid, "error", bot: "alice") != nil
           end) == :ok

    entry = find_outcome(activity_uuid, "error", bot: "alice")
    assert entry["reason"] =~ "boom"
  end
end
