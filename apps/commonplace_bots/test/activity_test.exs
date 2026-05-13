defmodule Commonplace.Bots.ActivityTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Activity
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_activity_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_room do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  test "ensure_doc creates the __bot_activity doc and links it under the room" do
    room = mint_room()
    assert {:ok, activity_uuid} = Activity.ensure_doc(room, CommitStoreClient)
    assert is_binary(activity_uuid)
  end

  test "ensure_doc is idempotent" do
    room = mint_room()
    assert {:ok, u1} = Activity.ensure_doc(room, CommitStoreClient)
    assert {:ok, u2} = Activity.ensure_doc(room, CommitStoreClient)
    assert u1 == u2
  end

  test "append/3 + list/2 round-trip an entry" do
    room = mint_room()
    {:ok, uuid} = Activity.ensure_doc(room, CommitStoreClient)

    :ok =
      Activity.append(
        uuid,
        %{
          "room" => "demo",
          "bot" => "alice",
          "decision" => "fired",
          "message_id" => "m1"
        },
        CommitStoreClient
      )

    entries = Activity.list(uuid, CommitStoreClient)
    assert length(entries) == 1
    [entry] = entries
    assert entry["decision"] == "fired"
    assert entry["bot"] == "alice"
    assert entry["room"] == "demo"
    assert is_binary(entry["ts"])
  end

  test "append/3 stamps ts when missing; preserves it when present" do
    room = mint_room()
    {:ok, uuid} = Activity.ensure_doc(room, CommitStoreClient)

    :ok =
      Activity.append(uuid, %{"decision" => "skipped"}, CommitStoreClient)

    :ok =
      Activity.append(uuid, %{"decision" => "fired", "ts" => "2026-01-01T00:00:00Z"},
        CommitStoreClient
      )

    [first, second] = Activity.list(uuid, CommitStoreClient)
    assert is_binary(first["ts"])
    assert first["ts"] != "2026-01-01T00:00:00Z"
    assert second["ts"] == "2026-01-01T00:00:00Z"
  end
end
