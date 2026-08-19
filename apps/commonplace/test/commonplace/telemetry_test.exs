defmodule Commonplace.TelemetryTest do
  use ExUnit.Case

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_telemetry_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_telemetry_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  test "commit create emits telemetry event", %{store: store} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:commonplace, :commit, :create]])

    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)

    assert_received {[:commonplace, :commit, :create], ^ref, %{system_time: _},
                     %{doc_uuid: ^uuid}}
  end

  test "sync emits stop event with duration and change count", %{store: store} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:commonplace, :sync, :stop]])

    sync_dir = Path.join(System.tmp_dir!(), "cp_tel_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(sync_dir)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    Commonplace.Sync.Watcher.sync_recursive(root_uuid, sync_dir, store)

    assert_received {[:commonplace, :sync, :stop], ^ref, %{duration: _, changes: 0},
                     %{root_uuid: ^root_uuid, dir: ^sync_dir}}

    File.rm_rf!(sync_dir)
  end

  test "sync emits start and stop events", %{store: store} do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:commonplace, :sync, :start],
        [:commonplace, :sync, :stop]
      ])

    sync_dir = Path.join(System.tmp_dir!(), "cp_tel_sync2_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(sync_dir)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    Commonplace.Sync.Watcher.sync_recursive(root_uuid, sync_dir, store)

    assert_received {[:commonplace, :sync, :start], ^ref, %{system_time: _},
                     %{root_uuid: ^root_uuid, dir: ^sync_dir}}

    assert_received {[:commonplace, :sync, :stop], ^ref, %{duration: duration, changes: 0},
                     %{root_uuid: ^root_uuid, dir: ^sync_dir}}
                    when is_integer(duration)

    File.rm_rf!(sync_dir)
  end

  test "console logger can be attached and detached" do
    assert :ok = Commonplace.Telemetry.attach_console_logger()
    assert :ok = Commonplace.Telemetry.detach_console_logger()
  end
end
