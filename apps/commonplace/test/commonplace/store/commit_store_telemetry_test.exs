defmodule Commonplace.Store.CommitStoreTelemetryTest do
  @moduledoc """
  CX-9hql (R4c rung-0): CommitStore write-path telemetry.

  The R4c decision rejected write-sharding absent evidence and demanded
  instrumentation of rung-1 (CPU inside handle_call) and rung-2 (single
  mailbox) FIRST. This pins the two new events:

    * `[:commonplace, :commit_store, :call]` — once per WRITE-verb
      handle_call, carrying handle-call duration and the mailbox depth
      sampled at entry (the rung-2 signal).
    * `[:commonplace, :commit_store, :write_cpu]` — CPU-share breakdown
      (build/sign/validate/persist) for the two commit-building paths
      that do real work inside the serialized section.

  Reads must NOT emit `:call` — they mostly bypass the GenServer via
  persistent_term already (CX-tdkq.4); this is a regression guard for that.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cs_telemetry_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"cs_telemetry_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp text_doc(s) do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, s)
    Encoding.encode_update(doc)
  end

  defp attach(event) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "#{inspect(event)}-#{inspect(ref)}",
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(event)}-#{inspect(ref)}") end)
  end

  test "create_chained_commit emits :call with verb, non-negative duration/queue_len, correct doc_uuid",
       %{store: store} do
    attach([:commonplace, :commit_store, :call])

    uuid = "chained-#{:rand.uniform(1_000_000)}"
    commit = CommitStore.create_chained_commit(store, uuid, text_doc("hello"))
    assert commit.doc_uuid == uuid

    assert_receive {:telemetry, [:commonplace, :commit_store, :call], measurements, metadata}
    assert metadata.verb == :create_chained_commit
    assert metadata.doc_uuid == uuid
    assert is_integer(measurements.duration)
    assert measurements.duration >= 0
    assert is_integer(measurements.queue_len)
    assert measurements.queue_len >= 0
  end

  test "import_commit emits both :call and :write_cpu (validate present) for a valid commit",
       %{store: store} do
    attach([:commonplace, :commit_store, :call])
    attach([:commonplace, :commit_store, :write_cpu])

    uuid = "import-#{:rand.uniform(1_000_000)}"
    commit = Commit.new(uuid, text_doc("peer"), nil, %{})

    assert :ok = CommitStore.import_commit(store, commit)

    assert_receive {:telemetry, [:commonplace, :commit_store, :call], _meas, call_meta}
    assert call_meta.verb == :import_commit
    assert call_meta.doc_uuid == uuid

    assert_receive {:telemetry, [:commonplace, :commit_store, :write_cpu], cpu_meas, cpu_meta}
    assert cpu_meta.verb == :import_commit
    assert cpu_meta.doc_uuid == uuid
    assert is_integer(cpu_meas.validate)
    assert cpu_meas.validate > 0
  end

  test "write_snapshot_cas emits :call with verb :write_snapshot_cas", %{store: store} do
    attach([:commonplace, :commit_store, :call])

    uuid = "cas-#{:rand.uniform(1_000_000)}"

    assert {:ok, _commit} =
             CommitStore.write_snapshot_cas(store, uuid, text_doc("snap"), %{}, nil)

    assert_receive {:telemetry, [:commonplace, :commit_store, :call], _meas, metadata}
    assert metadata.verb == :write_snapshot_cas
    assert metadata.doc_uuid == uuid
  end

  test "a read (commit_log) emits no :call event", %{store: store} do
    attach([:commonplace, :commit_store, :call])

    uuid = "read-#{:rand.uniform(1_000_000)}"
    CommitStore.create_chained_commit(store, uuid, text_doc("x"))

    # Drain the write's own :call event first.
    assert_receive {:telemetry, [:commonplace, :commit_store, :call], _, _}

    _log = CommitStore.commit_log(store, uuid)

    refute_receive {:telemetry, [:commonplace, :commit_store, :call], _, _}, 100
  end

  test "write_cpu on the create path has all four keys and persist > 0", %{store: store} do
    attach([:commonplace, :commit_store, :write_cpu])

    uuid = "create-#{:rand.uniform(1_000_000)}"
    _commit = CommitStore.create_chained_commit(store, uuid, text_doc("y"))

    assert_receive {:telemetry, [:commonplace, :commit_store, :write_cpu], measurements, metadata}
    assert metadata.doc_uuid == uuid
    assert Map.has_key?(measurements, :build)
    assert Map.has_key?(measurements, :sign)
    assert Map.has_key?(measurements, :validate)
    assert Map.has_key?(measurements, :persist)
    assert measurements.persist > 0
  end

  test "queue poller, when enabled with a short interval, emits :queue_depth with integer queue_len" do
    dir = Path.join(System.tmp_dir!(), "cp_cs_poller_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"cs_poller_store_#{:rand.uniform(1_000_000_000)}"

    old = Application.get_env(:commonplace, :commit_store_queue_poll_ms)
    Application.put_env(:commonplace, :commit_store_queue_poll_ms, 20)

    on_exit(fn ->
      if old, do: Application.put_env(:commonplace, :commit_store_queue_poll_ms, old),
        else: Application.delete_env(:commonplace, :commit_store_queue_poll_ms)

      File.rm_rf!(dir)
    end)

    attach([:commonplace, :commit_store, :queue_depth])

    start_supervised!(%{
      id: name,
      start: {CommitStore, :start_link, [[data_dir: dir, name: name]]}
    })

    assert_receive {:telemetry, [:commonplace, :commit_store, :queue_depth], measurements, metadata},
                    1_000

    assert metadata.store == name
    assert is_integer(measurements.queue_len)
    assert measurements.queue_len >= 0
  end
end
