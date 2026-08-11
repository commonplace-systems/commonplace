defmodule Commonplace.BootWriterMeasurementTest do
  @moduledoc """
  S13 boot-writer regression fixture.

  The pre-fix measurement recorded three unsigned GitBridge denials per boot:
  presence genesis, workspace-root attach, and `set_activity`. These tests keep
  that live-shaped root mapping, but pin the ruled signed behavior and both
  fail-closed arms.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Crypto.{AgentKeys, NodeIdentity, Signing}
  alias Commonplace.GitBridge.{Inbound, Server}
  alias Commonplace.Store.{CommitStoreClient, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Encoding

  @missing_key_text "bridge-agent signing key missing (LBD-4: a principal that cannot provision must NOT appear)"
  @minimal_text "workspace class 'minimal' does not accept root entry '__git-bridge.bot' — declared in profile"

  setup do
    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      gate: Application.get_env(:commonplace, :local_write_gate),
      trust: Application.get_env(:commonplace, :trust)
    }

    on_exit(fn ->
      put_or_delete(:data_dir, old.data_dir)
      put_or_delete(:local_write_gate, old.gate)
      put_or_delete(:trust, old.trust)
    end)

    :ok
  end

  test "bridge presence and activity are bridge-agent signed with zero denials across two boots" do
    fixture = fixture!(:legacy_default)
    identity_uuid = Inbound.bridge_identity_uuid(fixture.root_uuid)

    # Operator/provisioning phase, before the bridge boots. Production boot is
    # read-only against AgentKeys custody and must never call ensure/2.
    assert {:ok, pub} = AgentKeys.ensure(identity_uuid, fixture.secret_store)

    boot_1 = boot_bridge!(fixture, 1)
    boot_2 = boot_bridge!(fixture, 2)

    assert boot_1.denials == []
    assert boot_2.denials == []
    assert boot_1.presence_uuid == boot_2.presence_uuid

    root_doc = load_doc(fixture.store, fixture.root_uuid)
    assert {:ok, entry} = Schema.get_entry(root_doc, "__git-bridge.bot")
    assert entry.node_id == boot_2.presence_uuid

    presence = Commonplace.Presence.read(entry.node_id, fixture.store)
    assert presence["bound_identity"] == identity_uuid
    assert presence["activity"] == "idle"

    assert {:ok, latest_presence_commit} =
             CommitStoreClient.latest_commit(fixture.store, entry.node_id)

    assert latest_presence_commit.signer_id == Signing.signer_id(identity_uuid, pub)
    assert :ok = Signing.verify_commit(latest_presence_commit, pub)

    assert {:ok, root_attach_commit} =
             CommitStoreClient.latest_commit(fixture.store, fixture.root_uuid)

    assert root_attach_commit.signer_id == Signing.signer_id(identity_uuid, pub)
    assert :ok = Signing.verify_commit(root_attach_commit, pub)

    IO.inspect(
      %{
        before_denials_per_boot: 3,
        after_denials: [length(boot_1.denials), length(boot_2.denials)],
        attach: {fixture.root_uuid, "__git-bridge.bot", entry.node_id},
        signer_id: latest_presence_commit.signer_id
      },
      label: "S13 SIGNED BOOT RECEIPT"
    )
  end

  test "missing bridge key skips loudly once without a write or crash" do
    fixture = fixture!(:legacy_default)
    before_docs = CommitStoreClient.all_doc_uuids(fixture.store)
    {:ok, before_root_head} = CommitStoreClient.latest_commit(fixture.store, fixture.root_uuid)
    before_root_id = before_root_head.id

    {log, boot} =
      capture_boot_log(fn ->
        boot_bridge!(fixture, :missing_key)
      end)

    assert boot.denials == []
    assert boot.presence_uuid == nil
    assert log =~ @missing_key_text
    assert length(:binary.matches(log, @missing_key_text)) == 1
    assert CommitStoreClient.all_doc_uuids(fixture.store) == before_docs

    assert {:ok, %{id: ^before_root_id}} =
             CommitStoreClient.latest_commit(fixture.store, fixture.root_uuid)

    assert :error =
             Schema.get_entry(load_doc(fixture.store, fixture.root_uuid), "__git-bridge.bot")
  end

  test "minimal workspace refuses the registered bridge attach loudly without failing boot" do
    fixture = fixture!(:minimal)
    identity_uuid = Inbound.bridge_identity_uuid(fixture.root_uuid)
    assert {:ok, _pub} = AgentKeys.ensure(identity_uuid, fixture.secret_store)
    before_docs = CommitStoreClient.all_doc_uuids(fixture.store)
    {:ok, before_root_head} = CommitStoreClient.latest_commit(fixture.store, fixture.root_uuid)
    before_root_id = before_root_head.id

    {log, boot} = capture_boot_log(fn -> boot_bridge!(fixture, :minimal) end)

    assert boot.denials == []
    assert boot.presence_uuid == nil
    assert log =~ @minimal_text
    assert length(:binary.matches(log, @minimal_text)) == 1
    assert CommitStoreClient.all_doc_uuids(fixture.store) == before_docs

    assert {:ok, %{id: ^before_root_id}} =
             CommitStoreClient.latest_commit(fixture.store, fixture.root_uuid)

    assert :error =
             Schema.get_entry(load_doc(fixture.store, fixture.root_uuid), "__git-bridge.bot")
  end

  defp fixture!(profile) do
    suffix = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "cp_s13_fix_#{suffix}")
    repo_dir = Path.join(data_dir, "mirror")
    bridge_data_dir = Path.join(data_dir, "git_bridges")
    File.mkdir_p!(bridge_data_dir)

    store = :"s13_fix_store_#{suffix}"
    secrets = :"s13_fix_secrets_#{suffix}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: data_dir,
       name: :"s13_fix_store_sup_#{suffix}",
       commit_store_name: store,
       trust_side_store_name: :"s13_fix_tss_#{suffix}",
       pending_imports_name: :"s13_fix_pi_#{suffix}"},
      id: :"s13_fix_store_sup_#{suffix}"
    )

    start_supervised!(
      {SecretStore, data_dir: data_dir, name: secrets, auto_compact: false},
      id: secrets
    )

    Application.put_env(:commonplace, :data_dir, data_dir)
    Application.put_env(:commonplace, :local_write_gate, :off)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    # Provision the node anchor while this is still a genuine first boot. The
    # GitBridge never provisions this or its own AgentKeys custody.
    assert {:ok, _node_ctx} = NodeIdentity.signing_context()

    root_uuid = UUID.uuid4()
    chat_uuid = UUID.uuid4()
    bd_uuid = UUID.uuid4()

    for uuid <- [chat_uuid, bd_uuid] do
      assert %Commonplace.Store.Commit{} =
               CommitStoreClient.create_chained_commit(
                 store,
                 uuid,
                 Encoding.encode_update(Schema.new_schema())
               )
    end

    root_doc =
      case profile do
        :legacy_default ->
          Schema.new_schema()
          |> Schema.add_directory("chat", chat_uuid)
          |> Schema.add_directory("bd", bd_uuid)

        :minimal ->
          Schema.new_schema()
          |> Schema.put_workspace_profile(:minimal)
      end

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               root_uuid,
               Encoding.encode_update(root_doc)
             )

    File.write!(Path.join(data_dir, "root"), root_uuid)

    File.write!(
      Path.join(bridge_data_dir, "git_bridges.json"),
      Jason.encode!([
        %{
          "mount_uuid" => root_uuid,
          "repo_dir" => repo_dir,
          "remote" => nil,
          "branch" => "main",
          "interval_ms" => 3_600_000
        }
      ])
    )

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    %{
      data_dir: data_dir,
      repo_dir: repo_dir,
      bridge_data_dir: bridge_data_dir,
      root_uuid: root_uuid,
      store: store,
      secret_store: secrets
    }
  end

  defp boot_bridge!(fixture, boot) do
    ref = {__MODULE__, boot, System.unique_integer([:positive])}
    parent = self()
    store_pid = Process.whereis(fixture.store)

    :telemetry.attach(
      ref,
      [:commonplace, :commit, :rejected, :local_trust],
      fn _event, _measurements, metadata, _config ->
        if self() == store_pid, do: send(parent, {:s13_denial, ref, metadata})
      end,
      nil
    )

    supervisor = :"s13_bridge_sup_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Commonplace.GitBridge.Supervisor,
       name: supervisor,
       store: fixture.store,
       secret_store: fixture.secret_store,
       data_dir: fixture.bridge_data_dir},
      id: supervisor
    )

    [{_, server, :worker, _}] = Supervisor.which_children(supervisor)
    _ = :sys.get_state(server)
    presence_uuid = Server.status(server).presence_uuid
    denials = drain_denials(ref, [])
    :telemetry.detach(ref)
    stop_supervised(supervisor)

    %{presence_uuid: presence_uuid, denials: denials}
  end

  defp drain_denials(ref, acc) do
    receive do
      {:s13_denial, ^ref, metadata} -> drain_denials(ref, [metadata | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp load_doc(store, uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
    doc
  end

  defp capture_boot_log(fun) do
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:boot_result, fun.()})
      end)

    assert_receive {:boot_result, result}
    {log, result}
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:commonplace, key)
  defp put_or_delete(key, value), do: Application.put_env(:commonplace, key, value)
end
