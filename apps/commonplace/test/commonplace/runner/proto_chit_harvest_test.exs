defmodule Commonplace.Runner.ProtoChitHarvestTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.ProtoChit
  alias Commonplace.ProtoChit.IntentRecord
  alias Commonplace.Runner.{Launcher, PodProfile, ProtoChitHarvest}

  @moduletag timeout: 600_000

  test "harvest surface exposes its verification entry point" do
    assert Code.ensure_loaded?(Commonplace.Runner.ProtoChitHarvest)
    assert function_exported?(Commonplace.Runner.ProtoChitHarvest, :harvest, 2)
  end

  test "harvest surface exposes its quarantine artifact" do
    assert Code.ensure_loaded?(Commonplace.Runner.ProtoChitHarvest)
    assert function_exported?(Commonplace.Runner.ProtoChitHarvest, :quarantine_path, 2)
  end

  test "real provisioned pod exposes the wired proto-chit arm" do
    root = Path.join(System.tmp_dir!(), "a1b_pod_arm_#{UUID.uuid4()}")
    pods_root = Path.join(root, "pods")
    File.mkdir_p!(pods_root)
    launcher = start_supervised!({Launcher, pods_root: pods_root, dedicated_runner_service: true})

    repo = Path.expand("../../../../..", __DIR__)
    source_repo = Path.join(root, "source")
    {"", 0} = System.cmd("git", ["clone", "--quiet", "--no-hardlinks", repo, source_repo])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source_repo)
    {principal_pubkey, _private_key} = Signing.generate_keypair()

    invocation = [
      "/bin/sh",
      "-c",
      "git config user.email pod@example.invalid && " <>
        "git config user.name 'A1B Pod' && " <>
        "git commit --allow-empty -m 'A1B unseen arm' >\"$COMMONPLACE_DATA_DIR/a1b-emitter.txt\" 2>&1; " <>
        "status=$?; printf '%s' \"$status\" >\"$COMMONPLACE_DATA_DIR/a1b-git-status.tmp\"; " <>
        "mv \"$COMMONPLACE_DATA_DIR/a1b-git-status.tmp\" \"$COMMONPLACE_DATA_DIR/a1b-git-status\"; " <>
        "while test ! -f \"$COMMONPLACE_DATA_DIR/a1b-stop\"; do sleep 0.05; done"
    ]

    assert {:ok, handle} =
             Launcher.launch(launcher, manifest(), profile(),
               repo: source_repo,
               sha: String.trim(sha),
               principal_pubkey: principal_pubkey,
               proto_chit_commonplace:
                 Path.expand("../../../../commonplace_cli/commonplace_cli", __DIR__),
               invocation: invocation
             )

    data_dir = Path.join([handle.pod_home, "workspace", ".commonplace"])
    assert {:ok, "0"} = await_file(Path.join(data_dir, "a1b-git-status"))
    assert {:ok, output} = await_file(Path.join(data_dir, "a1b-emitter.txt"))

    wal_path = Path.join([data_dir, "proto-chit", "events.wal.ndjson"])
    wal = if File.exists?(wal_path), do: File.read!(wal_path), else: ""
    records = wal |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    deployment =
      data_dir |> Path.join("proto-chit-deployment.json") |> File.read!() |> Jason.decode!()

    {local_store_supervisor, local_store} = open_store!(data_dir)
    local_log = ProtoChit.chain(deployment["event-log-uuid"], store: local_store)
    Supervisor.stop(local_store_supervisor)

    IO.puts("A1B_POD_EMITTER_OUTPUT_BEGIN\n#{output}A1B_POD_EMITTER_OUTPUT_END")
    IO.puts("A1B_POD_WAL_RECORDS=#{length(records)}")
    IO.puts("A1B_POD_WAL_FAILURES=#{inspect(Enum.map(records, & &1["failure"]))}")
    IO.puts("A1B_POD_WAL_AUTH=#{inspect(Enum.map(records, & &1["authentication"]))}")
    IO.puts("A1B_POD_LOCAL_EVENT_LOG=#{inspect(local_log)}")
    assert local_log == {:ok, []}

    File.write!(Path.join(data_dir, "a1b-stop"), "stop\n")
    assert :ok = Launcher.reap(handle)

    [record] = records

    assert record["authentication"] == %{
             "reason" => "deployment-signer-unavailable",
             "state" => "unsigned"
           }

    assert {:ok, []} = ProtoChit.chain(deployment["event-log-uuid"])

    quarantine_path =
      ProtoChitHarvest.quarantine_path(
        Path.join(pods_root, ".proto-chit-quarantine"),
        deployment["event-log-uuid"]
      )

    assert [quarantine] = quarantine_path |> File.read!() |> String.split("\n", trim: true)

    assert %{"record-name" => "events.wal.ndjson:1", "reason" => ":unsigned"} =
             Jason.decode!(quarantine)

    IO.puts(
      "A1B_POD_HARVEST_QUARANTINE=#{inspect(Map.take(Jason.decode!(quarantine), ["record-name", "reason"]))}"
    )

    refute File.exists?(handle.pod_home)
    File.rm_rf!(root)
  end

  test "one flipped-byte record is quarantined by name while genuine records ingest" do
    root = Path.join(System.tmp_dir!(), "a1b_refusal_#{UUID.uuid4()}")
    pod_home = Path.join(root, "pod")
    data_dir = Path.join([pod_home, "workspace", ".commonplace"])
    state_dir = Path.join(data_dir, "proto-chit")
    quarantine_root = Path.join(root, "quarantine")
    File.mkdir_p!(state_dir)

    assert {:ok, pod_signer} = NodeIdentity.signing_context(data_dir)
    event_log_uuid = UUID.uuid4()
    write_deployment!(data_dir, state_dir, event_log_uuid, pod_signer.identity_uuid)

    genuine = signed_record!(pod_signer, "genuine pod commit", String.duplicate("a", 40))
    tampered = put_in(genuine, ["event", "message"], "fenuine pod commit")
    wal_path = Path.join(state_dir, "events.wal.ndjson")
    File.write!(wal_path, Jason.encode!(genuine) <> "\n" <> Jason.encode!(tampered) <> "\n")

    store = start_store!(Path.join(root, "host-store"))

    assert {:ok,
            %{
              ingested: [%{name: "events.wal.ndjson:1"}],
              quarantined: [
                %{
                  name: "events.wal.ndjson:2",
                  reason: :invalid_signature,
                  path: quarantine_path
                }
              ]
            }} =
             ProtoChitHarvest.harvest(pod_home,
               store: store,
               quarantine_root: quarantine_root
             )

    assert {:ok, [entry]} = ProtoChit.chain(event_log_uuid, store: store)
    assert entry.event["message"] == "genuine pod commit"
    assert entry.event["author-principal"] == pod_signer.identity_uuid
    assert entry.signer.signed
    assert String.starts_with?(entry.signer.signer_id, pod_signer.identity_uuid)

    assert entry.event["intent-record"]["authentication"]["signature"] ==
             genuine["authentication"]["signature"]

    assert entry.event["predecessor-ref"]["unresolved"] == []

    predecessor_path = Path.join(quarantine_root, event_log_uuid <> ".predecessors.json")
    assert %{"main" => event_ref} = predecessor_path |> File.read!() |> Jason.decode!()
    assert event_ref == entry.event_ref

    assert quarantine_path == ProtoChitHarvest.quarantine_path(quarantine_root, event_log_uuid)
    assert [quarantine] = quarantine_path |> File.read!() |> String.split("\n", trim: true)

    assert %{"record-name" => "events.wal.ndjson:2", "reason" => ":invalid_signature"} =
             Jason.decode!(quarantine)

    IO.puts("A1B_QUARANTINE_PATH=#{quarantine_path}")
    IO.puts("A1B_QUARANTINE_RECORD=#{quarantine}")
    File.rm_rf!(root)
  end

  test "reap preserves the pod home when harvest cannot verify its independent key" do
    root = Path.join(System.tmp_dir!(), "a1b_reap_refusal_#{UUID.uuid4()}")
    pods_root = Path.join(root, "pods")
    source_repo = Path.join(root, "source")
    File.mkdir_p!(pods_root)
    init_fixture_repo!(source_repo)

    launcher = start_supervised!({Launcher, pods_root: pods_root, dedicated_runner_service: true})
    {principal_pubkey, _private_key} = Signing.generate_keypair()
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source_repo)

    assert {:ok, handle} =
             Launcher.launch(launcher, manifest(), profile(),
               repo: source_repo,
               sha: String.trim(sha),
               principal_pubkey: principal_pubkey,
               invocation: [
                 "/bin/sh",
                 "-c",
                 "while ! test -f \"$COMMONPLACE_DATA_DIR/a1b-exit\"; do sleep 0.05; done"
               ]
             )

    public_artifact =
      Path.join([handle.pod_home, "workspace", ".commonplace", "node_signing_public_keys.json"])

    original_public_artifact = File.read!(public_artifact)
    File.write!(public_artifact, "not-json\n")
    File.write!(Path.join(Path.dirname(public_artifact), "a1b-exit"), "exit\n")

    assert :ok = await_dead(handle)
    assert File.dir?(handle.pod_home)

    File.write!(public_artifact, original_public_artifact)
    assert :ok = Launcher.reap(handle)
    refute File.exists?(handle.pod_home)
    File.rm_rf!(root)
  end

  defp await_file(path), do: await_file(path, System.monotonic_time(:millisecond) + 120_000)

  defp await_dead(handle),
    do: await_dead(handle, System.monotonic_time(:millisecond) + 30_000)

  defp await_dead(handle, deadline) do
    cond do
      not Launcher.alive?(handle) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        receive do
        after
          10 -> await_dead(handle, deadline)
        end
    end
  end

  defp await_file(path, deadline) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_file(path, deadline)
          end
        else
          {:error, :timeout}
        end

      error ->
        error
    end
  end

  defp profile do
    %PodProfile{
      id: "runner-local",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{},
      network: "none"
    }
  end

  defp signed_record!(signer, message, git_sha) do
    record = %{
      "wal-version" => 2,
      "status" => "pending",
      "replay-grade" => "pin-cut-at-replay",
      "failure" => "emitter-exit-1",
      "git-argv" => ["commit", "-m", message],
      "recorded-at" => "2026-08-20T00:00:00Z",
      "event" => %{
        "verb" => "commit",
        "author-principal" => signer.identity_uuid,
        "message" => message,
        "proto-pin" => nil,
        "predecessor-ref" => %{"branch" => "main", "event-refs" => []},
        "git-sha" => nil
      },
      "post-exec" => %{
        "disposition" => "skipped-main-emission-failed",
        "exit-status" => 0,
        "message" => message,
        "resulting-git-sha" => git_sha
      }
    }

    {:ok, signed} = IntentRecord.sign(record, signer)
    signed
  end

  defp write_deployment!(data_dir, state_dir, event_log_uuid, signer_id) do
    File.write!(
      Path.join(data_dir, "proto-chit-deployment.json"),
      Jason.encode!(%{
        "deployment-id" => "a1b-refusal",
        "event-log-uuid" => event_log_uuid,
        "signer-id" => signer_id,
        "state-dir" => state_dir,
        "wal-path" => Path.join(state_dir, "events.wal.ndjson")
      })
    )
  end

  defp start_store!(data_dir) do
    {_supervisor, store} = open_store!(data_dir)
    store
  end

  defp open_store!(data_dir) do
    n = System.unique_integer([:positive])
    store = :"a1b_harvest_store_#{n}"

    supervisor =
      start_supervised!(
        {Commonplace.Store.Supervisor,
         data_dir: data_dir,
         name: :"a1b_harvest_supervisor_#{n}",
         commit_store_name: store,
         trust_side_store_name: :"a1b_harvest_trust_#{n}",
         pending_imports_name: :"a1b_harvest_pending_#{n}"}
      )

    {supervisor, store}
  end

  defp init_fixture_repo!(repo) do
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README"), "A1B reap fixture\n")
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "a1b@example.invalid"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "A1B Fixture"], cd: repo)
    {_, 0} = System.cmd("git", ["add", "README"], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", "fixture"], cd: repo)
  end

  defp manifest do
    principal = UUID.uuid4()

    %{
      id: "a1b-unseen-arm",
      parent: "commonplace-factory",
      mission: "Measure the real pod proto-chit arm",
      principal: principal,
      workspace_class: "minimal",
      root_entries: [],
      authority: %{certs: [], authors_code: false, scope_note: nil},
      sync_scope: %{rule: "git-tracked-set", excludes: [".beads"], binary_extensions: []},
      sla: %{tier: "durable", retention: "indefinite", note: "pod-local"},
      environments: %{may_declare: false, requires_allowed: []},
      stewards: [principal],
      auditors: [UUID.uuid4()],
      escalate_to: "commonplace-factory",
      outputs: ["chits"],
      environment_faced: []
    }
  end
end
