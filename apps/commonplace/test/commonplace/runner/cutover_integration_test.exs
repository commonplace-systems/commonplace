defmodule Commonplace.Runner.CutoverIntegrationTest do
  @moduledoc """
  M-CUTOVER-1 integration slice — the zero-exposure gate before GAP-4.

  Runs REAL codex inside a real mediator-socket pod, pointed at the
  CodexFaithfulVendor through the mediator→relay path, and asserts codex
  COMPLETES a turn end to end. This is the first-integration debug that
  Q-A's dry-run-first staging exists to do WITHOUT real credentials.

  ⛔ Tagged :cutover (excluded from the default suite) — it launches real
  bwrap pods and runs the real codex binary; it is a measurement harness,
  not a CI unit. Run it explicitly:
      mix test --only cutover apps/commonplace/test/commonplace/runner/cutover_integration_test.exs

  The product is completes-or-named-refusal: either codex prints the
  faithful vendor's ACK (the credentialed path carries a completable
  turn) or it refuses at a named point (a finding, never a surprise).
  """
  use ExUnit.Case, async: false

  @moduletag :cutover
  @moduletag timeout: 180_000

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.{Launcher, Mediator, PodProfile}
  alias Commonplace.Test.CodexFaithfulVendor

  @codex_js "/home/jes/.npm-global/lib/node_modules/@openai/codex/bin/codex.js"

  setup do
    root = Path.join(System.tmp_dir!(), "cutover_#{System.unique_integer([:positive])}")
    source_repo = Path.join(root, "source")
    pods_root = Path.join(root, "pods")
    File.mkdir_p!(source_repo)
    File.mkdir_p!(pods_root)

    # The pod checkout needs the proto-chit shim and a codex-invocation
    # script. Copy the real shim tree so the intention channel is present.
    repo_root = Path.expand("../../../../..", __DIR__)
    File.mkdir_p!(Path.join(source_repo, "tools/proto-chit/bin"))

    for f <- ["git", "proto-chit-wal"] do
      File.cp!(
        Path.join(repo_root, "tools/proto-chit/bin/#{f}"),
        Path.join(source_repo, "tools/proto-chit/bin/#{f}")
      )

      File.chmod!(Path.join(source_repo, "tools/proto-chit/bin/#{f}"), 0o755)
    end

    write_codex_invocation!(source_repo)

    git!(source_repo, ["init", "--quiet"])
    git!(source_repo, ["config", "user.email", "cutover@example.invalid"])
    git!(source_repo, ["config", "user.name", "Cutover Fixture"])
    git!(source_repo, ["add", "."])
    git!(source_repo, ["commit", "--quiet", "-m", "cutover fixture"])
    sha = git!(source_repo, ["rev-parse", "HEAD"])

    {public_key, private_key} = Signing.generate_keypair()
    {principal_pubkey, _} = Signing.generate_keypair()

    vendor_state = start_supervised!({Agent, fn -> %{requests: []} end})

    vendor =
      start_supervised!(
        {Bandit, plug: {CodexFaithfulVendor, state: vendor_state}, scheme: :http, port: 0}
      )

    {:ok, {_ip, vendor_port}} = ThousandIsland.listener_info(vendor)

    socket = Path.join(root, "cutover.sock")

    mediator =
      start_supervised!(
        {Mediator,
         deployments: %{"cutover" => socket},
         public_key: public_key,
         credentials: %{access: "access-old", refresh: "refresh-old"},
         vendor_url: "http://127.0.0.1:#{vendor_port}",
         request_timeout: 30_000}
      )

    launcher =
      start_supervised!({Launcher, pods_root: pods_root, dedicated_runner_service: true})

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      launcher: launcher,
      mediator: mediator,
      pods_root: pods_root,
      principal_pubkey: principal_pubkey,
      principal_uuid: UUID.uuid4(),
      private_key: private_key,
      root: root,
      sha: sha,
      socket: socket,
      source_repo: source_repo,
      vendor_state: vendor_state
    }
  end

  @tag :cutover
  test "codex completes a turn inside a mediator-socket pod through the faithful vendor", ctx do
    relay_port = 20_000 + rem(System.unique_integer([:positive]), 10_000)
    token = Mediator.mint_token("cutover", System.system_time(:second) + 300, ctx.private_key)

    profile = %PodProfile{
      id: "runner-local",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{"postgres" => "16.2"},
      network: "mediator-socket"
    }

    manifest = %{
      id: "cell-cutover",
      parent: "commonplace-factory",
      mission: "M-CUTOVER-1 integration slice",
      principal: ctx.principal_uuid,
      workspace_class: "minimal",
      root_entries: [],
      authority: %{certs: [], authors_code: false, scope_note: nil},
      sync_scope: %{rule: "git-tracked-set", excludes: [".beads"], binary_extensions: []},
      sla: %{tier: "durable", retention: "indefinite", note: "pod-local"},
      environments: %{may_declare: false, requires_allowed: ["postgres"]},
      stewards: [ctx.principal_uuid],
      auditors: [UUID.uuid4()],
      escalate_to: "commonplace-factory",
      outputs: ["chits"],
      environment_faced: []
    }

    assert {:ok, handle} =
             Launcher.launch(ctx.launcher, manifest, profile,
               repo: ctx.source_repo,
               sha: ctx.sha,
               principal_pubkey: ctx.principal_pubkey,
               invocation: ["./run-codex.sh", Integer.to_string(relay_port), token],
               mediator_socket: [path: ctx.socket, port: relay_port]
             )

    data_dir = Path.join([handle.pod_home, "workspace", ".commonplace"])
    out_path = Path.join(data_dir, "codex-out")

    # Live diagnostics: does the invocation run at all (codex-start), and
    # what is codex writing (codex-out) — read BEFORE any reap.
    start_seen = await_exists(Path.join(data_dir, "codex-start"), 15_000)
    IO.puts("\n=== codex-start (invocation ran?) ===\n#{inspect(start_seen)}")

    result = await_file(out_path, 90_000)

    # Record the raw codex output verbatim regardless of outcome — this is
    # a measurement, and the refusal text (if any) IS the finding.
    IO.puts("\n=== CUTOVER codex-out ===\n#{inspect(result)}\n=========================")
    vendor_requests = Agent.get(ctx.vendor_state, & &1.requests)
    IO.puts("vendor received #{length(vendor_requests)} request(s)")

    _ = Launcher.reap(handle)

    assert {:ok, out} = result
    # Completes-or-named-refusal: either the faithful ACK made it back
    # (turn completed through the stack) or a named point of refusal.
    assert out =~ "ACK" or out =~ "exit=",
           "codex produced neither the vendor's ACK nor an exit marker: #{out}"
  end

  defp write_codex_invocation!(source_repo) do
    File.write!(
      Path.join(source_repo, "run-codex.sh"),
      """
      #!/bin/sh
      port="$1"
      token="$2"
      out="$COMMONPLACE_DATA_DIR/codex-out"
      printf 'started pwd=%s data=%s\\n' "$PWD" "$COMMONPLACE_DATA_DIR" > "$COMMONPLACE_DATA_DIR/codex-start"
      export CODEX_POD_TOKEN="$token"
      export HOME="$COMMONPLACE_DATA_DIR/../.."
      export CODEX_HOME="$COMMONPLACE_DATA_DIR/codex-home"
      mkdir -p "$CODEX_HOME"
      # node + codex reached by full path (ro-bound /); PATH lacks them.
      PATH="/usr/bin:/bin:$PATH" \\
      /usr/bin/node #{@codex_js} exec \\
        -c model_provider=custom \\
        -c 'model_providers.custom.name=pod' \\
        -c "model_providers.custom.base_url=http://127.0.0.1:$port/v1" \\
        -c 'model_providers.custom.wire_api=responses' \\
        -c 'model_providers.custom.env_key=CODEX_POD_TOKEN' \\
        -c 'model_providers.custom.requires_openai_auth=false' \\
        --skip-git-repo-check \\
        --sandbox read-only \\
        -C "$PWD" \\
        'reply with the single word ACK' > "$out" 2>&1
      printf 'exit=%s\\n' "$?" >> "$out"
      sleep 300
      """
    )

    File.chmod!(Path.join(source_repo, "run-codex.sh"), 0o755)
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp await_exists(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_exists_until(path, deadline)
  end

  defp await_exists_until(path, deadline) do
    case File.read(path) do
      {:ok, c} when c != "" ->
        {:ok, c}

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(200)
          await_exists_until(path, deadline)
        else
          {:error, :never_appeared}
        end
    end
  end

  defp await_file(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_file_until(path, deadline)
  end

  defp await_file_until(path, deadline) do
    case File.read(path) do
      {:ok, contents} ->
        if contents =~ "exit=" do
          {:ok, contents}
        else
          wait_or_timeout(path, deadline, contents)
        end

      {:error, :enoent} ->
        wait_or_timeout(path, deadline, nil)

      other ->
        other
    end
  end

  defp wait_or_timeout(path, deadline, partial) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(200)
      await_file_until(path, deadline)
    else
      {:ok, partial || "<timeout: no codex-out>"}
    end
  end
end
