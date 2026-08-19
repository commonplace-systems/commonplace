defmodule Commonplace.Reflog.CheckpointTimerTest do
  use ExUnit.Case, async: false

  alias Commonplace.Reflog.CheckpointTimer
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_timer_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)

    store_name = :"timer_store_#{:rand.uniform(999_999)}"
    {:ok, store} = CommitStore.start_link(data_dir: dir, name: store_name)

    # Create a root with a file
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    file_uuid = UUID.uuid4()
    root_doc = Schema.add_file(root_doc, "test.txt", file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_chained_commit(store, root_uuid, update)

    # Create the file doc
    doc = Yelixer.Doc.new()
    doc_update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, file_uuid, doc_update)

    on_exit(fn ->
      if Process.alive?(store),
        do:
          (try do
             GenServer.stop(store)
           catch
             (:exit, _ -> :ok)
           end)

      File.rm_rf!(dir)
    end)

    %{store: store, store_name: store_name, root_uuid: root_uuid}
  end

  test "checkpoint_now creates a checkpoint", %{store_name: store_name, root_uuid: root_uuid} do
    {:ok, timer} =
      CheckpointTimer.start_link(
        root_uuid: root_uuid,
        store: store_name,
        owner: "test",
        interval: 60_000,
        name: :"timer_#{:rand.uniform(999_999)}"
      )

    assert {:ok, commit_id} = CheckpointTimer.checkpoint_now(timer)
    assert is_binary(commit_id)
    assert byte_size(commit_id) == 32

    GenServer.stop(timer)
  end

  test "timer triggers periodic checkpoints", %{store_name: store_name, root_uuid: root_uuid} do
    {:ok, timer} =
      CheckpointTimer.start_link(
        root_uuid: root_uuid,
        store: store_name,
        owner: "test",
        interval: 100,
        name: :"timer_fast_#{:rand.uniform(999_999)}"
      )

    # Wait for at least one tick
    Process.sleep(250)

    # Checkpoint should have happened
    # Verify by checking the reflog branch exists
    schema =
      case CommitStore.latest_commit(store_name, root_uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema()
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema()
      end

    assert {:ok, _} = Schema.get_entry(schema, "__reflog")

    GenServer.stop(timer)
  end
end
