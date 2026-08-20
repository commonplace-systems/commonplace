defmodule Commonplace.Runner.ProtoChitHarvestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Commonplace.Crypto.Signing
  alias Commonplace.ProtoChit
  alias Commonplace.ProtoChit.IntentRecord
  alias Commonplace.Runner.{Launcher, PodIdentity, PodProfile, ProtoChitHarvest}

  @moduletag timeout: 600_000

  test "harvest surface exposes its verification entry point" do
    assert Code.ensure_loaded?(Commonplace.Runner.ProtoChitHarvest)
    assert function_exported?(Commonplace.Runner.ProtoChitHarvest, :harvest, 2)
  end

  test "harvest surface exposes its quarantine artifact" do
    assert Code.ensure_loaded?(Commonplace.Runner.ProtoChitHarvest)
    assert function_exported?(Commonplace.Runner.ProtoChitHarvest, :quarantine_path, 2)
  end

  test "A1C: pod commit signs WAL and harvest persists it under the bound pod signer" do
    root = Path.join(System.tmp_dir!(), "a1c_pod_arm_#{UUID.uuid4()}")
    pods_root = Path.join(root, "pods")
    File.mkdir_p!(pods_root)
    launcher = start_supervised!({Launcher, pods_root: pods_root, dedicated_runner_service: true})

    repo = Path.expand("../../../../..", __DIR__)
    source_repo = Path.join(root, "source")
    {"", 0} = System.cmd("git", ["clone", "--quiet", "--no-hardlinks", repo, source_repo])
    install_worktree_wal!(repo, source_repo)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source_repo)
    {principal_pubkey, _private_key} = Signing.generate_keypair()
    pod_manifest = manifest()
    commonplace_cli = compiled_cli_wrapper!(repo)

    invocation = [
      "/bin/sh",
      "-c",
      "if printf tamper >\"$COMMONPLACE_DATA_DIR/../../proto-chit-deployment-binding.json\" 2>/dev/null; " <>
        "then binding=writable; else binding=read-only; fi; " <>
        "printf '%s' \"$binding\" >\"$COMMONPLACE_DATA_DIR/a1c-binding-access\"; " <>
        "git config user.email pod@example.invalid && " <>
        "git config user.name 'A1C Pod' && " <>
        "git commit --allow-empty -m 'A1C pod commit' >\"$COMMONPLACE_DATA_DIR/a1c-emitter.txt\" 2>&1; " <>
        "status=$?; printf '%s' \"$status\" >\"$COMMONPLACE_DATA_DIR/a1c-git-status.tmp\"; " <>
        "mv \"$COMMONPLACE_DATA_DIR/a1c-git-status.tmp\" \"$COMMONPLACE_DATA_DIR/a1c-git-status\"; " <>
        "while test ! -f \"$COMMONPLACE_DATA_DIR/a1c-stop\"; do sleep 0.05; done"
    ]

    assert {:ok, handle} =
             Launcher.launch(launcher, pod_manifest, profile(),
               repo: source_repo,
               sha: String.trim(sha),
               principal_pubkey: principal_pubkey,
               proto_chit_commonplace: commonplace_cli,
               invocation: invocation
             )

    data_dir = Path.join([handle.pod_home, "workspace", ".commonplace"])

    assert {:ok, binding_path_effect} =
             await_file(Path.join(data_dir, "a1c-binding-access"))

    assert binding_path_effect in ["read-only", "writable"]
    assert {:ok, "0"} = await_file(Path.join(data_dir, "a1c-git-status"))
    assert {:ok, output} = await_file(Path.join(data_dir, "a1c-emitter.txt"))

    wal_path = Path.join([data_dir, "proto-chit", "events.wal.ndjson"])
    wal = if File.exists?(wal_path), do: File.read!(wal_path), else: ""
    records = wal |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    deployment =
      data_dir |> Path.join("proto-chit-deployment.json") |> File.read!() |> Jason.decode!()

    binding =
      handle.pod_home
      |> Path.join("proto-chit-deployment-binding.json")
      |> File.read!()
      |> Jason.decode!()

    assert binding == deployment
    refute binding == "tamper"
    IO.puts("A1C_POD_BINDING_PATH_EFFECT=#{binding_path_effect}; host binding unchanged")

    {local_store_supervisor, local_store} = open_store!(data_dir)
    local_log = ProtoChit.chain(deployment["event-log-uuid"], store: local_store)
    Supervisor.stop(local_store_supervisor)

    IO.puts("A1C_POD_EMITTER_OUTPUT_BEGIN\n#{output}A1C_POD_EMITTER_OUTPUT_END")
    IO.puts("A1C_POD_WAL_RECORDS=#{length(records)}")
    IO.puts("A1C_POD_WAL_FAILURES=#{inspect(Enum.map(records, & &1["failure"]))}")
    IO.puts("A1C_POD_WAL_AUTH=#{inspect(Enum.map(records, & &1["authentication"]))}")
    IO.puts("A1C_POD_LOCAL_EVENT_LOG=#{inspect(local_log)}")
    assert local_log == {:ok, []}

    [record] = records
    public_key = Base.decode64!(deployment["signer-public-key"])
    assert :ok = IntentRecord.verify(record, public_key)
    assert record["authentication"]["state"] == "signed"
    assert record["authentication"]["principal"] == deployment["signer-id"]
    assert record["event"]["author-principal"] == deployment["signer-id"]
    assert deployment["durable-identity"] == pod_manifest.principal
    refute deployment["signer-id"] == deployment["durable-identity"]

    File.write!(Path.join(data_dir, "a1c-stop"), "stop\n")
    assert :ok = Launcher.reap(handle)

    assert {:ok, [entry]} = ProtoChit.chain(deployment["event-log-uuid"])
    assert entry.event["message"] == "A1C pod commit"
    assert entry.event["author-principal"] == deployment["signer-id"]
    assert String.starts_with?(entry.signer.signer_id, deployment["signer-id"] <> "@")

    log_output =
      capture_io(fn ->
        host_data_dir = Application.fetch_env!(:commonplace, :data_dir)

        assert 0 ==
                 Commonplace.CLI.ProtoChit.run(host_data_dir, "", [
                   "log",
                   "--event-log",
                   deployment["event-log-uuid"]
                 ])
      end)

    IO.puts("A1C_PROTO_CHIT_LOG_BEGIN\n#{log_output}A1C_PROTO_CHIT_LOG_END")
    assert log_output =~ "commit  by #{deployment["signer-id"]}  [signature present]"
    assert log_output =~ "message: A1C pod commit"

    refute File.exists?(handle.pod_home)
    File.rm_rf!(root)
  end

  test "A1C: wrong key, no key, and broken signature are three named quarantine facts" do
    root = Path.join(System.tmp_dir!(), "a1c_refusal_#{UUID.uuid4()}")
    pod_home = Path.join(root, "pod")
    data_dir = Path.join([pod_home, "workspace", ".commonplace"])
    state_dir = Path.join(data_dir, "proto-chit")
    quarantine_root = Path.join(root, "quarantine")
    File.mkdir_p!(state_dir)

    assert {:ok, pod_signer} = PodIdentity.mint(data_dir)
    event_log_uuid = UUID.uuid4()
    write_deployment!(pod_home, data_dir, state_dir, event_log_uuid, pod_signer)

    genuine = signed_record!(pod_signer, "genuine pod commit", String.duplicate("a", 40))
    assert {:ok, wrong_signer} = PodIdentity.mint(Path.join(root, "wrong-signer"))

    deployment_path = Path.join(data_dir, "proto-chit-deployment.json")
    original_deployment = File.read!(deployment_path)

    tampered_deployment =
      original_deployment
      |> Jason.decode!()
      |> Map.put("signer-public-key", Base.encode64(wrong_signer.public_key))

    File.write!(deployment_path, Jason.encode!(tampered_deployment))
    store = start_store!(Path.join(root, "host-store"))

    assert {:error, :deployment_binding_mismatch} =
             ProtoChitHarvest.harvest(pod_home,
               store: store,
               quarantine_root: quarantine_root
             )

    File.write!(deployment_path, original_deployment)

    wrong_key = signed_record!(wrong_signer, "wrong key", String.duplicate("b", 40))
    no_key = IntentRecord.unsigned(Map.delete(genuine, "authentication"))
    broken_signature = put_in(genuine, ["event", "message"], "broken signature")
    wal_path = Path.join(state_dir, "events.wal.ndjson")

    File.write!(
      wal_path,
      Enum.map_join([genuine, wrong_key, no_key, broken_signature], "\n", &Jason.encode!/1) <>
        "\n"
    )

    quarantine_path = ProtoChitHarvest.quarantine_path(quarantine_root, event_log_uuid)

    assert {:ok,
            %{
              ingested: [%{name: "events.wal.ndjson:1"}],
              quarantined: [
                %{name: "events.wal.ndjson:2", reason: :public_key_mismatch},
                %{name: "events.wal.ndjson:3", reason: :unsigned},
                %{name: "events.wal.ndjson:4", reason: :invalid_signature}
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

    quarantines =
      quarantine_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(quarantines, &Map.take(&1, ["record-name", "reason"])) == [
             %{"record-name" => "events.wal.ndjson:2", "reason" => ":public_key_mismatch"},
             %{"record-name" => "events.wal.ndjson:3", "reason" => ":unsigned"},
             %{"record-name" => "events.wal.ndjson:4", "reason" => ":invalid_signature"}
           ]

    IO.puts(
      "A1C_QUARANTINE_FACTS=#{inspect(Enum.map(quarantines, &Map.take(&1, ["record-name", "reason"])))}"
    )

    File.rm_rf!(root)
  end

  test "reap preserves the pod home when the bound ephemeral key is corrupt" do
    root = Path.join(System.tmp_dir!(), "a1c_reap_refusal_#{UUID.uuid4()}")
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
                 "while ! test -f \"$COMMONPLACE_DATA_DIR/a1c-exit\"; do sleep 0.05; done"
               ]
             )

    pod_key = Path.join([handle.pod_home, "workspace", ".commonplace", "pod_signing_key"])

    original_pod_key = File.read!(pod_key)
    File.write!(pod_key, "not-json\n")
    File.write!(Path.join(Path.dirname(pod_key), "a1c-exit"), "exit\n")

    assert :ok = await_dead(handle)
    assert File.dir?(handle.pod_home)

    File.write!(pod_key, original_pod_key)
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

  defp write_deployment!(pod_home, data_dir, state_dir, event_log_uuid, signer) do
    deployment = %{
      "binding-version" => "pod-home-read-only-v1",
      "deployment-id" => "a1c-refusal",
      "event-log-uuid" => event_log_uuid,
      "signer-id" => signer.identity_uuid,
      "signer-public-key" => Base.encode64(signer.public_key),
      "state-dir" => state_dir,
      "wal-path" => Path.join(state_dir, "events.wal.ndjson")
    }

    File.write!(
      Path.join(pod_home, "proto-chit-deployment-binding.json"),
      Jason.encode!(deployment)
    )

    File.write!(Path.join(data_dir, "proto-chit-deployment.json"), Jason.encode!(deployment))
  end

  defp install_worktree_wal!(repo, source_repo) do
    relative = "tools/proto-chit/bin/proto-chit-wal"
    File.cp!(Path.join(repo, relative), Path.join(source_repo, relative))

    {_, 0} = System.cmd("git", ["add", relative], cd: source_repo)

    # The copy exists to guarantee the fixture repo carries the CURRENT WAL
    # helper. Before this round landed, the worktree's helper differed from
    # the fixture clone's and the commit was real; once the round is on main
    # the bytes are identical and git correctly says "nothing to commit" —
    # which is success for this helper's purpose, not a failure. Asserting
    # {_, 0} unconditionally made the test landing-hostile: green in the
    # round's worktree, red on the merged tree (measured 2026-08-20).
    {staged, 0} = System.cmd("git", ["diff", "--cached", "--name-only"], cd: source_repo)

    if String.trim(staged) != "" do
      {_, 0} =
        System.cmd(
          "git",
          [
            "-c",
            "user.email=a1c@example.invalid",
            "-c",
            "user.name=A1C Fixture",
            "commit",
            "--quiet",
            "-m",
            "A1C fixture WAL signer path"
          ],
          cd: source_repo
        )
    end

    :ok
  end

  defp compiled_cli_wrapper!(repo) do
    wrapper = Path.join([repo, "_build", "test", "a1c-commonplace"])
    erl_libs = Path.join([repo, "_build", "test", "lib"])
    elixir = System.find_executable("elixir")

    File.write!(
      wrapper,
      "#!/bin/sh\n" <>
        "if test \"${3:-}\" = proto-chit && test \"${4:-}\" = sign-intent; then\n" <>
        "  ERL_LIBS=#{erl_libs} exec #{elixir} -e 'data_dir = Enum.at(System.argv(), 1); System.halt(Commonplace.CLI.ProtoChit.run(data_dir, \"\", [\"sign-intent\"]))' -- \"$@\"\n" <>
        "fi\n" <>
        "exit 1\n"
    )

    File.chmod!(wrapper, 0o755)
    wrapper
  end

  defp start_store!(data_dir) do
    {_supervisor, store} = open_store!(data_dir)
    store
  end

  defp open_store!(data_dir) do
    n = System.unique_integer([:positive])
    store = :"a1c_harvest_store_#{n}"

    supervisor =
      start_supervised!(
        {Commonplace.Store.Supervisor,
         data_dir: data_dir,
         name: :"a1c_harvest_supervisor_#{n}",
         commit_store_name: store,
         trust_side_store_name: :"a1c_harvest_trust_#{n}",
         pending_imports_name: :"a1c_harvest_pending_#{n}"}
      )

    {supervisor, store}
  end

  defp init_fixture_repo!(repo) do
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README"), "A1C reap fixture\n")
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "a1c@example.invalid"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "A1C Fixture"], cd: repo)
    {_, 0} = System.cmd("git", ["add", "README"], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "--quiet", "-m", "fixture"], cd: repo)
  end

  defp manifest do
    principal = UUID.uuid4()

    %{
      id: "a1c-pod-signer",
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
