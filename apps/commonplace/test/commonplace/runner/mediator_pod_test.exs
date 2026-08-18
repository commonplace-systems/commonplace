defmodule Commonplace.Runner.MediatorPodTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.{Launcher, Mediator, PodProfile}
  alias Commonplace.Test.MediatorFakeVendor

  setup do
    root = Path.join(System.tmp_dir!(), "mediator_pod_r2_#{System.unique_integer([:positive])}")
    source_repo = Path.join(root, "source")
    pods_root = Path.join(root, "pods")
    File.mkdir_p!(source_repo)
    File.mkdir_p!(pods_root)

    write_workers(source_repo)
    git!(source_repo, ["init", "--quiet"])
    git!(source_repo, ["config", "user.email", "mediator-pod@example.invalid"])
    git!(source_repo, ["config", "user.name", "Mediator Pod Fixture"])
    git!(source_repo, ["add", "."])
    git!(source_repo, ["commit", "--quiet", "-m", "fixture"])

    {public_key, private_key} = Signing.generate_keypair()
    {principal_pubkey, _principal_private_key} = Signing.generate_keypair()
    vendor_state = start_supervised!({Agent, fn -> %{mode: :refresh, requests: []} end})

    vendor =
      start_supervised!(
        {Bandit,
         plug: {MediatorFakeVendor, owner: self(), state: vendor_state}, scheme: :http, port: 0}
      )

    {:ok, {_ip, vendor_port}} = ThousandIsland.listener_info(vendor)
    Agent.update(vendor_state, &Map.put(&1, :url, "http://127.0.0.1:#{vendor_port}"))

    sockets = %{
      "deployment-a" => Path.join(root, "a.sock"),
      "deployment-b" => Path.join(root, "b.sock")
    }

    mediator =
      start_supervised!(
        {Mediator,
         deployments: sockets,
         public_key: public_key,
         credentials: %{access: "access-old", refresh: "refresh-old"},
         vendor_url: "http://127.0.0.1:#{vendor_port}",
         request_timeout: 500}
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
      sha: git!(source_repo, ["rev-parse", "HEAD"]),
      sockets: sockets,
      source_repo: source_repo
    }
  end

  test "absence: posture none does not bind the mediator socket into the pod", ctx do
    handle =
      launch!(ctx, "absence", none_profile(), ["./absence.sh", ctx.sockets["deployment-a"]])

    assert {:ok, "absent\n"} = await_file(effect_path(handle, "absence"))
    assert :ok = Launcher.reap(handle)
  end

  test "surgical revocation through two in-pod relays refuses A by name and preserves B", ctx do
    port_a = unused_tcp_port()
    port_b = unused_tcp_port()
    token_a = token(ctx, "deployment-a")
    token_b = token(ctx, "deployment-b")

    a =
      launch_mediator!(ctx, "deployment-a", port_a, [
        "./request-loop.sh",
        Integer.to_string(port_a),
        token_a,
        "a"
      ])

    b =
      launch_mediator!(ctx, "deployment-b", port_b, [
        "./request-loop.sh",
        Integer.to_string(port_b),
        token_b,
        "b"
      ])

    trigger(a, "a", 1)
    trigger(b, "b", 1)
    assert await_file(effect_path(a, "result-a-1")) |> successful_response?()
    assert await_file(effect_path(b, "result-b-1")) |> successful_response?()

    :ok = Mediator.revoke_token(ctx.mediator, token_a)
    trigger(a, "a", 2)
    trigger(b, "b", 2)

    assert {:ok, refused} = await_file(effect_path(a, "result-a-2"))
    assert refused =~ ~s({"refusal":"revoked_token"})
    assert refused =~ "\n400"
    assert await_file(effect_path(b, "result-b-2")) |> successful_response?()

    assert :ok = Launcher.reap(a)
    assert :ok = Launcher.reap(b)
  end

  test "relay process argv, environment, and open filesystem handles hold no credential", ctx do
    sentinel = "MEDIATOR_R2_TOKEN_MUST_NOT_ENTER_RELAY"
    port = unused_tcp_port()

    handle =
      launch_mediator!(ctx, "deployment-a", port, ["./inspect-relay.sh", sentinel])

    assert {:ok, inspection} = await_file(effect_path(handle, "relay-inspection"))
    assert inspection =~ "Commonplace.Runner.MediatorRelay':main_erl"
    refute inspection =~ sentinel
    refute inspection =~ "authorization"
    assert inspection =~ "filesystem\n/"
    assert :ok = Launcher.reap(handle)
  end

  test "mediator death is a bounded named failure through the in-pod relay", ctx do
    port = unused_tcp_port()
    token = token(ctx, "deployment-a")

    handle =
      launch_mediator!(ctx, "deployment-a", port, [
        "./request-loop.sh",
        Integer.to_string(port),
        token,
        "death"
      ])

    GenServer.stop(ctx.mediator)
    started_at = System.monotonic_time(:millisecond)
    trigger(handle, "death", 1)

    assert {:ok, response} = await_file(effect_path(handle, "result-death-1"), 2_000)
    assert response =~ ~s({"refusal":"mediator_unreachable"})
    assert response =~ "\n502"
    assert System.monotonic_time(:millisecond) - started_at < 2_000
    assert :ok = Launcher.reap(handle)
  end

  defp launch_mediator!(ctx, deployment_id, port, invocation) do
    launch!(ctx, deployment_id, mediator_profile(), invocation,
      mediator_socket: [path: ctx.sockets[deployment_id], port: port]
    )
  end

  defp launch!(ctx, id, profile, invocation, extra_opts \\ []) do
    opts =
      [
        repo: ctx.source_repo,
        sha: ctx.sha,
        principal_pubkey: ctx.principal_pubkey,
        invocation: invocation
      ] ++ extra_opts

    assert {:ok, handle} = Launcher.launch(ctx.launcher, manifest(ctx, id), profile, opts)
    handle
  end

  defp token(ctx, deployment_id) do
    Mediator.mint_token(deployment_id, System.system_time(:second) + 60, ctx.private_key)
  end

  defp trigger(handle, label, number) do
    File.write!(effect_path(handle, "go-#{label}-#{number}"), "go\n")
  end

  defp successful_response?({:ok, response}), do: String.ends_with?(response, "\n200")
  defp successful_response?(_other), do: false

  defp effect_path(handle, name) do
    Path.join([handle.pod_home, "workspace", ".commonplace", name])
  end

  defp await_file(path, timeout \\ 10_000) do
    await_file_until(path, System.monotonic_time(:millisecond) + timeout)
  end

  defp await_file_until(path, deadline) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_file_until(path, deadline)
          end
        else
          {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp none_profile, do: profile("none")
  defp mediator_profile, do: profile("mediator-socket")

  defp profile(network) do
    %PodProfile{
      id: "runner-local",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{"postgres" => "16.2"},
      network: network
    }
  end

  defp manifest(ctx, id) do
    %{
      id: "cell-#{id}",
      parent: "commonplace-factory",
      mission: "Exercise mediator pod wiring",
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
  end

  defp write_workers(source_repo) do
    File.write!(
      Path.join(source_repo, "absence.sh"),
      """
      #!/bin/sh
      if test -e "$1"; then result=present; else result=absent; fi
      printf '%s\n' "$result" > "$COMMONPLACE_DATA_DIR/absence"
      sleep 300
      """
    )

    File.write!(
      Path.join(source_repo, "request-loop.sh"),
      """
      #!/bin/sh
      port="$1"
      token="$2"
      label="$3"
      number=1
      while test "$number" -le 2; do
        while ! test -f "$COMMONPLACE_DATA_DIR/go-$label-$number"; do sleep 0.01; done
        curl --silent --show-error --max-time 2 \
          --header 'accept: text/event-stream' \
          --header "authorization: Bearer $token" \
          --data '{"input":"hello"}' \
          --write-out '\n%{http_code}' \
          "http://127.0.0.1:$port/v1/responses" \
          > "$COMMONPLACE_DATA_DIR/result-$label-$number.tmp"
        mv "$COMMONPLACE_DATA_DIR/result-$label-$number.tmp" \
          "$COMMONPLACE_DATA_DIR/result-$label-$number"
        number=$((number + 1))
      done
      sleep 300
      """
    )

    File.write!(
      Path.join(source_repo, "inspect-relay.sh"),
      """
      #!/bin/sh
      sentinel="$1"
      relay_pid=''
      for _attempt in $(seq 1 100); do
        relay_pid=$(pgrep -f "^[^ ]*/beam.smp .*Commonplace.Runner.MediatorRelay':main_erl" | head -n 1)
        test -n "$relay_pid" && break
        sleep 0.01
      done
      test -n "$relay_pid" || exit 71
      {
        printf 'cmdline\n'
        tr '\\000' '\\n' < "/proc/$relay_pid/cmdline"
        printf 'environment\n'
        tr '\\000' '\\n' < "/proc/$relay_pid/environ"
        printf 'filesystem\n'
        readlink "/proc/$relay_pid/root"
        readlink "/proc/$relay_pid/cwd"
        readlink "/proc/$relay_pid/exe"
        find "/proc/$relay_pid/fd" -maxdepth 1 -type l -exec readlink {} \\;
      } > "$COMMONPLACE_DATA_DIR/relay-inspection.tmp"
      mv "$COMMONPLACE_DATA_DIR/relay-inspection.tmp" \
        "$COMMONPLACE_DATA_DIR/relay-inspection"
      test -n "$sentinel"
      sleep 300
      """
    )

    for worker <- ["absence.sh", "request-loop.sh", "inspect-relay.sh"] do
      File.chmod!(Path.join(source_repo, worker), 0o755)
    end
  end

  defp unused_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
