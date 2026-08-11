defmodule Commonplace.BootWriterMeasurementTest do
  @moduledoc """
  Measurement-only fixture for the 2026-08-11 S13 boot-writer census.

  This file deliberately traces production functions without changing them. Each
  boot gets a distinct tmp store containing a legacy-absent root whose schema has
  both `chat` and `bd` entries. Strict local-write enforcement is enabled only
  after seeding, with no trusted identities and no node key in the tmp data dir.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @trace_mfas [
    {Commonplace.Application, :ensure_chat_template_if_workspace_present, 1},
    {Commonplace.Chat.TemplateBootstrap, :ensure_template, 2},
    {Commonplace.MUD.Bootstrap, :ensure_doc_manifests, 1},
    {Commonplace.Green.Bursar, :create_state_doc, 2},
    {Commonplace.Green.Bursar, :create_log_doc, 2},
    {Commonplace.GitBridge.Server, :safe_create_presence, 2},
    {Commonplace.Presence, :create, 5},
    {Commonplace.Presence, :set_activity, 4},
    {CommitStoreClient, :create_commit, 6},
    {CommitStoreClient, :create_chained_commit, 5}
  ]

  setup do
    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      gate: Application.get_env(:commonplace, :local_write_gate),
      trust: Application.get_env(:commonplace, :trust),
      manifest: Application.get_env(:commonplace, :mud_engine_manifest)
    }

    on_exit(fn ->
      Enum.each(@trace_mfas, &:erlang.trace_pattern(&1, false, [:local]))
      :erlang.trace(:all, false, [:call])
      put_or_delete(:data_dir, old.data_dir)
      put_or_delete(:local_write_gate, old.gate)
      put_or_delete(:trust, old.trust)
      put_or_delete(:mud_engine_manifest, old.manifest)
    end)

    :ok
  end

  test "two live-shaped boots attribute every strict denial and re-mint fresh UUIDs" do
    boots = Enum.map(1..2, &run_boot/1)

    Enum.each(boots, fn boot ->
      assert length(boot.denials) == 3
      assert Enum.count(boot.denials, &(&1.doc_uuid == boot.root_uuid)) == 1
      assert Enum.all?(boot.denials, &(&1.reason == :unsigned))
      assert Enum.all?(boot.fresh_denials, &(not MapSet.member?(boot.schema_uuids, &1.doc_uuid)))
      assert [fresh_uuid, fresh_uuid] = Enum.map(boot.fresh_denials, & &1.doc_uuid)
    end)

    first_fresh = MapSet.new(Enum.map(Enum.at(boots, 0).fresh_denials, & &1.doc_uuid))
    second_fresh = MapSet.new(Enum.map(Enum.at(boots, 1).fresh_denials, & &1.doc_uuid))
    assert MapSet.disjoint?(first_fresh, second_fresh)

    IO.puts("\nS13 BOOT WRITER MEASUREMENT RECEIPTS")

    Enum.each(boots, fn boot ->
      IO.inspect(
        %{
          boot: boot.boot,
          root_uuid: boot.root_uuid,
          schema_uuids: MapSet.to_list(boot.schema_uuids),
          denials: boot.denials,
          trace: boot.trace
        },
        pretty: true,
        limit: :infinity
      )
    end)
  end

  defp run_boot(boot_number) do
    suffix = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "cp_s13_boot_writer_#{boot_number}_#{suffix}")
    File.mkdir_p!(data_dir)
    store = :"s13_boot_store_#{suffix}"

    pid = start_supervised!({CommitStore, data_dir: data_dir, name: store}, id: store)
    Application.put_env(:commonplace, :data_dir, data_dir)
    Application.put_env(:commonplace, :local_write_gate, :off)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :mud_engine_manifest, %{})

    fixture = seed_live_shape!(store, data_dir)

    assert {:error, {:node_signing_key_absent, :prior_world_present}} =
             Commonplace.Crypto.NodeIdentity.signing_context()

    trace_ref = make_ref()
    attach_denial_probe!(trace_ref, pid)
    enable_traces!()

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    assert :ok =
             Commonplace.Application.ensure_chat_template_if_workspace_present(store: store)

    assert :ok = Commonplace.MUD.Bootstrap.ensure_doc_manifests(store)

    bursar_name = :"s13_bursar_#{suffix}"

    start_supervised!(
      {Commonplace.Green.Bursar,
       root_uuid: fixture.root_uuid, store: store, name: bursar_name, sweep_interval: 3_600_000},
      id: bursar_name
    )

    _ = :sys.get_state(bursar_name)

    bridge_data_dir = Path.join(data_dir, "git_bridges")
    repo_dir = Path.join(data_dir, "mirror")
    File.mkdir_p!(bridge_data_dir)

    File.write!(
      Path.join(bridge_data_dir, "git_bridges.json"),
      Jason.encode!([
        %{
          "mount_uuid" => fixture.root_uuid,
          "repo_dir" => repo_dir,
          "remote" => nil,
          "branch" => "main",
          "interval_ms" => 3_600_000
        }
      ])
    )

    bridge_name = :"s13_git_bridge_#{suffix}"

    start_supervised!(
      {Commonplace.GitBridge.Supervisor,
       name: bridge_name, store: store, data_dir: bridge_data_dir},
      id: bridge_name
    )

    events = drain_events(trace_ref, [])
    disable_traces!()
    :telemetry.detach(trace_ref)
    stop_supervised(bridge_name)
    stop_supervised(bursar_name)
    stop_supervised(store)
    File.rm_rf!(data_dir)

    denials =
      for {:denial, receipt} <- events do
        receipt
      end

    trace =
      for {:trace, receipt} <- events do
        receipt
      end

    fresh_denials = Enum.reject(denials, &(&1.doc_uuid == fixture.root_uuid))

    %{
      boot: boot_number,
      root_uuid: fixture.root_uuid,
      schema_uuids: fixture.schema_uuids,
      denials: denials,
      fresh_denials: fresh_denials,
      trace: trace
    }
  end

  defp seed_live_shape!(store, data_dir) do
    compute_uuid = UUID.uuid4()
    template_uuid = UUID.uuid4()
    chat_uuid = UUID.uuid4()
    bd_uuid = UUID.uuid4()
    bursar_state_uuid = UUID.uuid4()
    bursar_log_uuid = UUID.uuid4()
    root_uuid = UUID.uuid4()

    compute_doc =
      Yelixer.Doc.new()
      |> ContentType.create(:text, "_compute")
      |> ContentType.insert_text(0, "defmodule ExistingTemplateCompute do\nend\n")

    template_schema =
      Schema.new_schema()
      |> Schema.add_file("_compute", compute_uuid)

    chat_schema =
      Schema.new_schema()
      |> Schema.add_directory("__template", template_uuid)

    bd_schema = Schema.new_schema()

    bursar_state_doc =
      Yelixer.Doc.new()
      |> ContentType.create(:text, "__bursar.json")
      |> ContentType.insert_text(0, "{}")

    bursar_log_doc =
      Yelixer.Doc.new()
      |> Yelixer.Doc.get_or_create_type("events", :array)
      |> elem(0)

    # Intentionally no Schema.put_workspace_profile/2: this is the live
    # legacy-absent population named by the brief.
    root_schema =
      Schema.new_schema()
      |> Schema.add_directory("chat", chat_uuid)
      |> Schema.add_directory("bd", bd_uuid)
      |> Schema.add_file("__bursar.json", bursar_state_uuid)
      |> Schema.add_file("__bursar.log", bursar_log_uuid)

    for {uuid, doc} <- [
          {compute_uuid, compute_doc},
          {template_uuid, template_schema},
          {chat_uuid, chat_schema},
          {bd_uuid, bd_schema},
          {bursar_state_uuid, bursar_state_doc},
          {bursar_log_uuid, bursar_log_doc},
          {root_uuid, root_schema}
        ] do
      assert %Commonplace.Store.Commit{} =
               CommitStoreClient.create_chained_commit(store, uuid, Encoding.encode_update(doc))
    end

    File.write!(Path.join(data_dir, "root"), root_uuid)

    %{
      root_uuid: root_uuid,
      schema_uuids:
        MapSet.new([
          root_uuid,
          chat_uuid,
          template_uuid,
          compute_uuid,
          bd_uuid,
          bursar_state_uuid,
          bursar_log_uuid
        ])
    }
  end

  defp attach_denial_probe!(ref, store_pid) do
    parent = self()

    :telemetry.attach(
      ref,
      [:commonplace, :commit, :rejected, :local_trust],
      fn _event, _measurements, metadata, _config ->
        send(parent, {
          :measurement_denial,
          ref,
          %{
            emitter_pid: self(),
            store_pid: store_pid,
            doc_uuid: metadata.doc_uuid,
            reason: metadata.reason,
            mode: metadata.mode
          }
        })
      end,
      nil
    )
  end

  defp enable_traces! do
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    Enum.each(@trace_mfas, fn {module, _function, _arity} = mfa ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(mfa, true, [:local])
    end)
  end

  defp disable_traces! do
    Enum.each(@trace_mfas, &:erlang.trace_pattern(&1, false, [:local]))
    :erlang.trace(:all, false, [:call])
  end

  defp drain_events(ref, acc) do
    receive do
      {:measurement_denial, ^ref, receipt} ->
        drain_events(ref, [{:denial, receipt} | acc])

      {:trace, pid, :call, {module, function, args}} ->
        receipt = %{
          pid: pid,
          writer: {module, function, length(args)},
          doc_uuid: traced_doc_uuid(module, function, args)
        }

        drain_events(ref, [{:trace, receipt} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp traced_doc_uuid(CommitStoreClient, :create_commit, [_store, uuid | _]), do: uuid
  defp traced_doc_uuid(CommitStoreClient, :create_chained_commit, [_store, uuid | _]), do: uuid
  defp traced_doc_uuid(_module, _function, _args), do: nil

  defp put_or_delete(key, nil), do: Application.delete_env(:commonplace, key)
  defp put_or_delete(key, value), do: Application.put_env(:commonplace, key, value)
end
