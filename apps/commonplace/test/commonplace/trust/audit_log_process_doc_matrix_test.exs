defmodule Commonplace.Trust.AuditLogProcessDocMatrixTest do
  @moduledoc """
  CX-s36k measurement: construct the four process/document combinations
  and observe whether each telemetry event writes an audit record.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Trust.{AuditDispatcher, AuditLog}

  @event [:commonplace, :commit, :rejected, :local_trust]

  setup do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "cp_audit_matrix_#{n}")
    store = :"audit_matrix_store_#{n}"
    dispatcher = :"audit_matrix_dispatcher_#{n}"
    task_supervisor = :"audit_matrix_tasks_#{n}"
    observer_id = "audit-matrix-observer-#{n}"
    test_pid = self()

    File.mkdir_p!(dir)

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"audit_matrix_supervisor_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"audit_matrix_trust_side_store_#{n}",
       pending_imports_name: :"audit_matrix_pending_imports_#{n}"}
    )

    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {AuditDispatcher,
       name: dispatcher,
       store: store,
       task_supervisor: task_supervisor,
       flush_ms: 10,
       enabled: true}
    )

    AuditLog.detach()
    AuditLog.reset_rate_table()
    assert :ok = AuditLog.attach(store, dispatcher: dispatcher)

    assert :ok =
             :telemetry.attach(
               observer_id,
               @event,
               fn event, _measurements, metadata, recipient ->
                 send(recipient, {:provocation, event, metadata, process_identity(self())})
               end,
               test_pid
             )

    on_exit(fn ->
      AuditLog.detach()
      :telemetry.detach(observer_id)
      File.rm_rf!(dir)
    end)

    %{dispatcher: dispatcher, store: store}
  end

  test "cell: unnamed process and audit-log own doc writes no record", context do
    assert {:registered_name, []} = Process.info(self(), :registered_name)

    result = exercise_cell(context, self(), AuditLog.log_uuid())

    assert [] = result.records
    assert result.provocation_process == process_identity(self())

    IO.puts(
      "CELL unnamed/foreign + audit-log-own-doc: record=no " <>
        "provocation_process=#{inspect(result.provocation_process)}"
    )
  end

  test "cell: unnamed process and some other doc writes a record", context do
    assert {:registered_name, []} = Process.info(self(), :registered_name)

    result = exercise_cell(context, self(), UUID.uuid4())

    assert [record] = result.records
    assert result.provocation_process == process_identity(self())
    assert record["firing_process"] == process_identity(self())

    IO.puts(
      "CELL unnamed/foreign + other-doc: record=yes " <>
        "firing_process=#{inspect(record["firing_process"])}"
    )
  end

  test "cell: inside CommitStore and audit-log own doc writes no record", context do
    store_pid = Process.whereis(context.store)
    refute is_nil(store_pid)

    result = exercise_cell(context, store_pid, AuditLog.log_uuid())

    assert [] = result.records
    assert result.provocation_process == process_identity(store_pid)

    IO.puts(
      "CELL CommitStore + audit-log-own-doc: record=no " <>
        "provocation_process=#{inspect(result.provocation_process)}"
    )
  end

  test "cell: inside CommitStore and some other doc writes a record", context do
    store_pid = Process.whereis(context.store)
    refute is_nil(store_pid)

    result = exercise_cell(context, store_pid, UUID.uuid4())

    assert [record] = result.records
    assert result.provocation_process == process_identity(store_pid)
    assert record["firing_process"] == process_identity(store_pid)

    IO.puts(
      "CELL CommitStore + other-doc: record=yes " <>
        "firing_process=#{inspect(record["firing_process"])}"
    )
  end

  defp exercise_cell(context, firing_pid, doc_uuid) do
    marker = "cx-s36k-#{UUID.uuid4()}"
    metadata = %{doc_uuid: doc_uuid, commit_id: marker, mode: :enforce, reason: :unsigned}

    emit_from(firing_pid, @event, metadata)

    assert_receive {:provocation, @event, ^metadata, provocation_process}
    assert :ok = AuditDispatcher.flush(context.dispatcher, 5_000)

    records =
      AuditLog.log_uuid()
      |> RedLog.load(context.store)
      |> RedLog.read()
      |> Enum.filter(&(&1["commit_id"] == marker))

    %{records: records, provocation_process: provocation_process}
  end

  defp emit_from(firing_pid, event, metadata) when firing_pid == self() do
    :telemetry.execute(event, %{system_time: System.system_time()}, metadata)
  end

  defp emit_from(store_pid, event, metadata) do
    _unchanged_state =
      :sys.replace_state(store_pid, fn state ->
        :telemetry.execute(event, %{system_time: System.system_time()}, metadata)
        state
      end)

    :ok
  end

  defp process_identity(pid) do
    registered_name =
      case Process.info(pid, :registered_name) do
        {:registered_name, name} when is_atom(name) -> Atom.to_string(name)
        {:registered_name, []} -> "unnamed"
      end

    %{"registered_name" => registered_name, "pid" => inspect(pid)}
  end
end
