defmodule Commonplace.CLI.EventTest do
  use ExUnit.Case

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_event_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_event_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  test "RedLog read returns appended events", %{store: store} do
    uuid = UUID.uuid4()
    log = RedLog.new(uuid, store)

    log =
      RedLog.append_raw(log, %{
        "type" => "stdout",
        "line" => "hello",
        "timestamp" => "2026-01-01T00:00:00Z"
      })

    log =
      RedLog.append_raw(log, %{
        "type" => "stderr",
        "line" => "error!",
        "timestamp" => "2026-01-01T00:00:01Z"
      })

    RedLog.commit(log)

    # Reload and read
    loaded = RedLog.load(uuid, store)
    events = RedLog.read(loaded)

    assert length(events) == 2
    assert Enum.at(events, 0)["line"] == "hello"
    assert Enum.at(events, 1)["line"] == "error!"
  end

  test "RedLog read returns empty list for non-existent log", %{store: store} do
    uuid = UUID.uuid4()
    log = RedLog.load(uuid, store)
    events = RedLog.read(log)
    assert events == []
  end

  test "--last option limits output", %{store: store} do
    uuid = UUID.uuid4()
    log = RedLog.new(uuid, store)

    log =
      Enum.reduce(1..10, log, fn i, acc ->
        RedLog.append_raw(acc, %{
          "type" => "stdout",
          "line" => "line #{i}",
          "timestamp" => "2026-01-01T00:00:#{String.pad_leading(to_string(i), 2, "0")}Z"
        })
      end)

    RedLog.commit(log)

    loaded = RedLog.load(uuid, store)
    events = RedLog.read(loaded)
    last_3 = Enum.take(events, -3)

    assert length(last_3) == 3
    assert Enum.at(last_3, 0)["line"] == "line 8"
    assert Enum.at(last_3, 1)["line"] == "line 9"
    assert Enum.at(last_3, 2)["line"] == "line 10"
  end

  test "format_event handles stdout and stderr", %{store: store} do
    uuid = UUID.uuid4()
    log = RedLog.new(uuid, store)

    log =
      RedLog.append_raw(log, %{
        "type" => "stdout",
        "line" => "ok",
        "timestamp" => "2026-01-01T12:30:45.123Z"
      })

    log =
      RedLog.append_raw(log, %{
        "type" => "stderr",
        "line" => "fail",
        "timestamp" => "2026-01-01T12:30:46.456Z"
      })

    RedLog.commit(log)

    loaded = RedLog.load(uuid, store)
    events = RedLog.read(loaded)

    assert length(events) == 2
    assert Enum.at(events, 0)["type"] == "stdout"
    assert Enum.at(events, 1)["type"] == "stderr"
  end
end
