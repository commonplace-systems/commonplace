defmodule Commonplace.Runner.LauncherTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.{Launcher, PodHandle, PodProfile}

  @canary_name "CX_POD_ENV_CANARY"
  @canary_value "pod-must-not-inherit-this-value"
  @custody_challenge "commonplace-pod-custody-v1"

  setup do
    fixture_root =
      Path.join(System.tmp_dir!(), "cp_launcher_#{UUID.uuid4()}")

    source_repo = Path.join(fixture_root, "source")
    pods_root = Path.join(fixture_root, "pods")
    File.mkdir_p!(source_repo)
    File.mkdir_p!(pods_root)
    uid = File.stat!("/proc/self").uid

    File.write!(
      Path.join(source_repo, "worker.sh"),
      """
      #!/bin/sh
      mkdir -p _build/runner
      printf 'built\n' > _build/runner/artifact
      count=0
      for entry in /proc/[0-9]*; do count=$((count + 1)); done
      printf '%s\n' "$count" > "$COMMONPLACE_DATA_DIR/process-count"
      printf '%s\n' "$HOME" > "$COMMONPLACE_DATA_DIR/worker-effect"
      env > "$COMMONPLACE_DATA_DIR/environment.tmp"
      mv "$COMMONPLACE_DATA_DIR/environment.tmp" "$COMMONPLACE_DATA_DIR/environment"
      printf '%s\n' "${#{@canary_name}-absent}" > "$COMMONPLACE_DATA_DIR/environment-canary"
      sleep 300 &
      wait
      """
    )

    File.write!(
      Path.join(source_repo, "channel-worker.sh"),
      """
      #!/bin/sh
      # Capture find's OWN output first. Writing "$?" after a pipeline records
      # the status of `sort -u`, which succeeds even when find matched nothing
      # and even when its search roots do not exist -- an assertion on that
      # value passes whether 0 or 23 channels were reachable.
      find /run/user/#{uid} /tmp -maxdepth 3 \\( -type s -o -type p \\) \
        > "$COMMONPLACE_DATA_DIR/reachable-channels-raw" 2>/dev/null
      xargs -r -n1 dirname < "$COMMONPLACE_DATA_DIR/reachable-channels-raw" \
        | sort -u > "$COMMONPLACE_DATA_DIR/reachable-channel-dirs"
      tmux list-panes -a > "$COMMONPLACE_DATA_DIR/tmux-output" 2> "$COMMONPLACE_DATA_DIR/tmux-error"
      # Publish the COUNT last and atomically so it is also the completion
      # marker for every artifact asserted below.
      wc -l < "$COMMONPLACE_DATA_DIR/reachable-channels-raw" \
        | tr -d ' ' > "$COMMONPLACE_DATA_DIR/reachable-channel-status.tmp"
      mv "$COMMONPLACE_DATA_DIR/reachable-channel-status.tmp" \
        "$COMMONPLACE_DATA_DIR/reachable-channel-status"
      sleep 300 &
      wait
      """
    )

    File.write!(
      Path.join(source_repo, "custody-worker.exs"),
      ~S"""
      data_dir = System.fetch_env!("COMMONPLACE_DATA_DIR")
      secrets_dir = Path.join(data_dir, "secrets")
      key_path = Path.join(secrets_dir, "pod_signing_key")
      challenge = "commonplace-pod-custody-v1"

      File.mkdir_p!(secrets_dir)
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      File.write!(
        key_path,
        Base.encode64(public_key) <> "\n" <> Base.encode64(private_key) <> "\n"
      )

      File.chmod!(key_path, 0o600)

      [stored_public_key, stored_private_key] =
        key_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Base.decode64!/1)

      signature =
        :crypto.sign(:eddsa, :none, challenge, [stored_private_key, :ed25519])

      durable_key_observation =
        case File.read(Path.join(data_dir, "node_signing_key")) do
          {:ok, ""} -> "masked:empty-device"
          {:error, :eacces} -> "masked:eacces"
          {:ok, contents} -> "readable:" <> Base.encode64(contents)
          {:error, reason} -> "check_failed:" <> inspect(reason)
        end

      report =
        [
          "schema=pod-custody-v1",
          "durable_key=" <> durable_key_observation,
          "pod_public_key=" <> Base.encode64(stored_public_key),
          "signature=" <> Base.encode64(signature)
        ]
        |> Enum.join("\n")
        |> Kernel.<>("\n")

      report_path = Path.join(data_dir, "pod-custody-report")
      File.write!(report_path <> ".tmp", report)
      File.rename!(report_path <> ".tmp", report_path)

      receive do
      after
        300_000 -> :ok
      end
      """
    )

    git!(source_repo, ["init", "--quiet"])
    git!(source_repo, ["config", "user.email", "launcher@example.invalid"])
    git!(source_repo, ["config", "user.name", "Launcher Fixture"])
    git!(source_repo, ["add", "worker.sh", "channel-worker.sh", "custody-worker.exs"])
    git!(source_repo, ["commit", "--quiet", "-m", "fixture"])

    {principal_pubkey, _principal_private_key} = Signing.generate_keypair()
    prior_canary = System.get_env(@canary_name)

    on_exit(fn ->
      restore_system_env(@canary_name, prior_canary)
      File.rm_rf!(fixture_root)
    end)

    %{
      source_repo: source_repo,
      pods_root: pods_root,
      sha: git!(source_repo, ["rev-parse", "HEAD"]),
      principal_uuid: UUID.uuid4(),
      principal_pubkey: principal_pubkey,
      uid: uid
    }
  end

  test "serve configuration cannot start a launcher without the dedicated runner declaration",
       ctx do
    serve_configuration = Application.get_all_env(:commonplace)
    refute Keyword.has_key?(serve_configuration, :dedicated_runner_service)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    undeclared_pods_root = Path.join(ctx.pods_root, "undeclared")
    declared_pods_root = Path.join(ctx.pods_root, "declared")

    undeclared =
      DynamicSupervisor.start_child(
        supervisor,
        {Launcher, Keyword.put(serve_configuration, :pods_root, undeclared_pods_root)}
      )

    declared =
      DynamicSupervisor.start_child(supervisor, {
        Launcher,
        pods_root: declared_pods_root, dedicated_runner_service: true
      })

    IO.puts("undeclared serve configuration: #{inspect(undeclared)}")
    IO.puts("declared runner configuration: #{inspect(declared)}")

    assert {:error, {:invalid_launcher, :dedicated_runner_service}} = undeclared
    assert {:ok, _launcher} = declared
    refute elem(undeclared, 0) == elem(declared, 0)
  end

  test "pod cannot read a canary injected by its launching BEAM", ctx do
    System.put_env(@canary_name, @canary_value)
    launcher = start_launcher!(ctx.pods_root)
    handle = launch!(launcher, ctx)
    data_dir = data_dir(handle)

    assert {:ok, canary_result} = await_file(Path.join(data_dir, "environment-canary"))
    assert String.trim(canary_result) == "absent"
    refute canary_result =~ @canary_value
    assert :ok = Launcher.reap(handle)
  end

  test "pod holds its own signing key and not the durable key, proven by effect", ctx do
    launcher = start_launcher!(ctx.pods_root)

    assert {:ok, handle} =
             Launcher.launch(launcher, manifest(ctx), profile(),
               repo: ctx.source_repo,
               sha: ctx.sha,
               principal_pubkey: ctx.principal_pubkey,
               invocation: custody_invocation()
             )

    data_dir = data_dir(handle)
    durable_key_contents = File.read!(Path.join(data_dir, "node_signing_key"))

    [durable_public_key_encoded, durable_private_key_encoded] =
      String.split(durable_key_contents, "\n", trim: true)

    assert durable_private_key_encoded != ""
    durable_public_key = Base.decode64!(durable_public_key_encoded)

    assert {:ok, report_contents} = await_file(Path.join(data_dir, "pod-custody-report"))
    report = custody_report(report_contents)

    assert report["schema"] == "pod-custody-v1"
    assert report["durable_key"] == "masked:eacces"
    refute String.starts_with?(report["durable_key"], "check_failed:")

    pod_public_key = Base.decode64!(report["pod_public_key"])
    signature = Base.decode64!(report["signature"])

    assert pod_public_key != durable_public_key

    assert :crypto.verify(:eddsa, :none, @custody_challenge, signature, [pod_public_key, :ed25519])

    refute :crypto.verify(
             :eddsa,
             :none,
             @custody_challenge,
             signature,
             [durable_public_key, :ed25519]
           )

    assert :ok = Launcher.reap(handle)
  end

  test "executes by effect with its provisioner-constructed environment", ctx do
    launcher = start_launcher!(ctx.pods_root)
    handle = launch!(launcher, ctx)
    data_dir = data_dir(handle)

    assert {:ok, home} = await_file(Path.join(data_dir, "worker-effect"))
    assert String.trim(home) == Path.join(handle.pod_home, "home")
    assert File.read!(Path.join(handle.pod_home, "checkout/_build/runner/artifact")) == "built\n"
    assert {:ok, environment} = await_file(Path.join(data_dir, "environment"))

    environment_names =
      environment
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))
      |> Enum.sort()

    assert length(environment_names) == 12

    assert environment_names ==
             ~w(COMMONPLACE_DATA_DIR HOME LANG LC_ALL PATH PROTO_CHIT_COMMONPLACE PROTO_CHIT_DATA_DIR PROTO_CHIT_EVENT_LOG_UUID PROTO_CHIT_REAL_GIT PROTO_CHIT_STATE_DIR PROTO_CHIT_SYNC_EXCLUDES PWD)

    assert {:ok, process_count} = File.read(Path.join(data_dir, "process-count"))
    assert String.to_integer(String.trim(process_count)) in 1..4
    assert Launcher.alive?(handle)
    assert :ok = Launcher.reap(handle)
  end

  test "live-process channels are unreachable behind containing-directory masks", ctx do
    runtime_dir = "/run/user/#{ctx.uid}"
    socket_dir = "/tmp/claude-chat"
    socket_path = Path.join(socket_dir, "launcher-test-#{UUID.uuid4()}.sock")
    File.mkdir_p!(socket_dir)
    {:ok, socket} = :gen_udp.open(0, [:binary, {:ifaddr, {:local, socket_path}}])

    on_exit(fn ->
      :ok = :gen_udp.close(socket)
      _ = File.rm(socket_path)
    end)

    assert Bitwise.band(File.lstat!(socket_path).mode, 0o170000) == 0o140000

    {host_channels_output, _host_find_status} =
      System.cmd("find", [
        socket_dir,
        "-maxdepth",
        "1",
        "(",
        "-type",
        "s",
        "-o",
        "-type",
        "p",
        ")"
      ])

    host_channels = String.split(host_channels_output, "\n", trim: true)
    assert host_channels != []
    assert socket_path in host_channels

    spec = Commonplace.Runner.Provisioner.sandbox_spec(profile(), ctx.pods_root)

    assert %{operation: :tmpfs, path: ^runtime_dir} =
             Enum.find(spec.masks, &(&1.name == :user_runtime_ipc))

    launcher = start_launcher!(ctx.pods_root)
    handle = launch!(launcher, ctx, "channel-worker.sh")
    data_dir = data_dir(handle)

    assert {:ok, channel_status} =
             await_file(
               Path.join(data_dir, "reachable-channel-status"),
               System.monotonic_time(:millisecond) + 5_000
             )

    assert String.trim(channel_status) == "0"

    assert {:ok, pod_channels_output} =
             File.read(Path.join(data_dir, "reachable-channels-raw"))

    refute socket_path in String.split(pod_channels_output, "\n", trim: true)
    assert File.read!(Path.join(data_dir, "reachable-channel-dirs")) == ""

    assert File.read!(Path.join(data_dir, "tmux-output")) == ""
    assert :ok = Launcher.reap(handle)
  end

  test "wrong handle fails while captured handle reaps the process unit", ctx do
    launcher = start_launcher!(ctx.pods_root)
    handle = launch!(launcher, ctx)
    assert {:ok, _effect} = await_file(Path.join(data_dir(handle), "worker-effect"))
    assert Launcher.alive?(handle)

    children = descendants_from_handle(handle.scope_pid)
    assert children != [], "the live-pod control must observe a non-empty descendant corpus"

    wrong_handle = %PodHandle{handle | ref: make_ref()}
    assert {:error, :unknown_pod_handle} = Launcher.reap(wrong_handle)
    assert Launcher.alive?(handle)

    assert :ok = Launcher.reap(handle)
    refute Launcher.alive?(handle)
    refute File.exists?(handle.pod_home)

    assert eventually(fn ->
             not File.dir?(Path.join("/proc", Integer.to_string(handle.scope_pid))) and
               Enum.all?(children, fn pid ->
                 not File.dir?(Path.join("/proc", Integer.to_string(pid)))
               end)
           end)
  end

  test "kill path has no process-name or argv-pattern selector, with positive control" do
    source_paths =
      Path.expand("../../../lib/commonplace/runner", __DIR__)
      |> Path.join("*.ex")
      |> Path.wildcard()

    assert length(source_paths) >= 4
    source = Enum.map_join(source_paths, "\n", &File.read!/1)
    assert String.length(source) > 0
    pattern_tools = ["p" <> "kill", "kill" <> "all"]

    prohibited =
      Regex.compile!(
        ~S/System\.cmd\(\s*"(?:/ <>
          Enum.join(pattern_tools, "|") <>
          ~S/)"|System\.cmd\(\s*"kill"[^\n]*"-f"/
      )

    refute Regex.match?(prohibited, source)
    positive_control = ~S|System.cmd("| <> hd(pattern_tools) <> ~S|", ["-f", process_name])|
    assert Regex.match?(prohibited, positive_control)
  end

  # A pod's stdout/stderr and exit status were captured by the port and discarded,
  # so bubblewrap could refuse with a precise diagnostic and the only observable was
  # a test timeout. Both arms are asserted here: a failing pod must SAY WHY, and a
  # succeeding pod must stay quiet -- a reporter that fires on healthy exits is
  # noise that trains readers to ignore it.
  test "a pod still running when the launcher stops has its output surfaced", ctx do
    launcher = start_launcher!(ctx.pods_root)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _handle} =
                 Launcher.launch(launcher, manifest(ctx), profile(),
                   repo: ctx.source_repo,
                   sha: ctx.sha,
                   principal_pubkey: ctx.principal_pubkey,
                   invocation: ["/bin/sh", "-c", "echo HANG-MARKER >&2; sleep 300"]
                 )

        # Give the launcher a chance to consume the port's output before stopping it.
        Process.sleep(200)
        :ok = GenServer.stop(launcher)
      end)

    assert log =~ "still running at launcher termination"
    assert log =~ "HANG-MARKER"
  end

  test "a pod that exits non-zero reports its status and its own output", ctx do
    launcher = start_launcher!(ctx.pods_root)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, handle} =
                 Launcher.launch(launcher, manifest(ctx), profile(),
                   repo: ctx.source_repo,
                   sha: ctx.sha,
                   principal_pubkey: ctx.principal_pubkey,
                   invocation: ["/bin/sh", "-c", "echo POD-DIAGNOSTIC-MARKER >&2; exit 3"]
                 )

        wait_until_dead!(handle)
      end)

    assert log =~ "exited with status 3"
    assert log =~ "POD-DIAGNOSTIC-MARKER"
  end

  test "a pod that exits zero reports nothing", ctx do
    launcher = start_launcher!(ctx.pods_root)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, handle} =
                 Launcher.launch(launcher, manifest(ctx), profile(),
                   repo: ctx.source_repo,
                   sha: ctx.sha,
                   principal_pubkey: ctx.principal_pubkey,
                   invocation: ["/bin/sh", "-c", "exit 0"]
                 )

        wait_until_dead!(handle)
      end)

    refute log =~ "exited with status"
  end

  defp wait_until_dead!(handle, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    cond do
      not Launcher.alive?(handle) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("pod never exited; the reporter under test could not have run")

      true ->
        Process.sleep(20)
        wait_until_dead!(handle, deadline)
    end
  end

  # The spec-level mask tests assert that an argv ENTRY EXISTS. That is shape equality,
  # and a mask that FAILS TO APPLY satisfies it just as well as one that applied: for
  # four days every pod died with "bwrap: Can't mkdir /tmp/tmux-1001: Read-only file
  # system" while those assertions stayed green. This asserts the EFFECT, and it is
  # machine-independent -- it holds where the host directory exists and where it does
  # not, which is exactly the difference that hid the bug.
  #
  # The pod writes its listing to data_dir rather than to stderr, and the test awaits a
  # separate done-marker FIRST. That ordering is the point: a bare `refute leaked` would
  # pass if the pod never ran at all, which is an absence with more than one cause.
  test "the pod sees an empty /tmp regardless of what the host has there", ctx do
    marker = "cp-fence-marker-#{System.unique_integer([:positive])}"
    host_marker = Path.join("/tmp", marker)
    File.mkdir_p!(host_marker)
    on_exit(fn -> File.rm_rf(host_marker) end)
    assert File.dir?(host_marker), "positive control: the marker must exist ON THE HOST"

    launcher = start_launcher!(ctx.pods_root)

    assert {:ok, handle} =
             Launcher.launch(launcher, manifest(ctx), profile(),
               repo: ctx.source_repo,
               sha: ctx.sha,
               principal_pubkey: ctx.principal_pubkey,
               invocation: [
                 "/bin/sh",
                 "-c",
                 # Write, then STAY ALIVE until reaped. The launcher removes the whole
                 # pod home -- data_dir included -- the moment the pod exits, so a pod
                 # that exits right after writing races the test's read and loses it
                 # roughly one time in six. Every other fixture worker already sleeps
                 # for exactly this reason; this one exited instantly and paid for it.
                 "ls -a /tmp > \"$COMMONPLACE_DATA_DIR/tmp-listing\"; " <>
                   "echo ran > \"$COMMONPLACE_DATA_DIR/probe-done\"; sleep 300"
               ]
             )

    data_dir = data_dir(handle)

    # POSITIVE CONTROL: until this file exists, the listing below proves nothing.
    # Deadline deliberately under ExUnit's 60s: a timeout here must fail as an
    # ASSERTION -- leaving budget for teardown, where a still-running pod's captured
    # output is the only diagnostic this test can leave behind in CI.
    case await_file(
           Path.join(data_dir, "probe-done"),
           System.monotonic_time(:millisecond) + 30_000
         ) do
      {:ok, _} ->
        :ok

      {:error, :timeout} ->
        # Diagnostic dump for an intermittent: enumerate every observable before dying,
        # because "probe-done absent" has more than one cause and they all look alike.
        pod_home = Path.dirname(data_dir)

        flunk("""
        probe-done never appeared. Observables at failure:
          pod alive?      #{inspect(Launcher.alive?(handle))}
          data_dir ls     #{inspect(File.ls(data_dir))}
          pod_home ls     #{inspect(File.ls(pod_home))}
          pods_root ls    #{inspect(File.ls(ctx.pods_root))}
        """)
    end

    assert {:ok, listing} = await_file(Path.join(data_dir, "tmp-listing"))

    entries = String.split(listing, "\n", trim: true)

    refute marker in entries,
           "host /tmp leaked into the pod: #{length(entries)} entries, " <>
             "including #{inspect(Enum.take(entries, 5))}"

    assert :ok = Launcher.reap(handle)
  end

  defp launch!(launcher, ctx, worker \\ "worker.sh") do
    assert {:ok, handle} =
             Launcher.launch(launcher, manifest(ctx), profile(),
               repo: ctx.source_repo,
               sha: ctx.sha,
               principal_pubkey: ctx.principal_pubkey,
               invocation: ["/bin/sh", worker]
             )

    handle
  end

  defp custody_invocation do
    elixir = runtime_executable!("elixir")
    erl = runtime_executable!("erl")

    runtime_path =
      [Path.dirname(erl), "/usr/local/bin", "/usr/bin", "/bin"]
      |> Enum.uniq()
      |> Enum.join(":")

    [
      "/usr/bin/env",
      "PATH=#{runtime_path}",
      elixir,
      "--erl",
      "+S 1:1 +SDio 1 +SDcpu 1",
      "custody-worker.exs"
    ]
  end

  defp runtime_executable!(name) do
    executable = System.find_executable(name) || flunk("#{name} executable is required")

    if Path.basename(Path.dirname(executable)) == "shims" do
      {resolved, 0} = System.cmd("asdf", ["which", name], stderr_to_stdout: true)
      String.trim(resolved)
    else
      executable
    end
  end

  defp custody_report(contents) do
    pairs =
      contents
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, "=", parts: 2) do
          [name, value] when name != "" and value != "" -> {name, value}
          _ -> flunk("pod custody report contains an empty or malformed result: #{inspect(line)}")
        end
      end)

    assert length(pairs) == 4
    report = Map.new(pairs)
    assert map_size(report) == 4
    assert Map.keys(report) |> Enum.sort() == ~w(durable_key pod_public_key schema signature)
    report
  end

  defp start_launcher!(pods_root) do
    start_supervised!({Launcher, pods_root: pods_root, dedicated_runner_service: true})
  end

  defp manifest(ctx) do
    %{
      id: "cell-launched",
      parent: "commonplace-factory",
      mission: "Execute a runner pod",
      principal: ctx.principal_uuid,
      workspace_class: "minimal",
      root_entries: [],
      authority: %{certs: [], authors_code: false, scope_note: nil},
      sync_scope: %{rule: "git-tracked-set", excludes: [".beads"], binary_extensions: [".png"]},
      sla: %{tier: "durable", retention: "indefinite", note: "pod-local"},
      environments: %{may_declare: false, requires_allowed: ["postgres"]},
      stewards: [ctx.principal_uuid],
      auditors: [UUID.uuid4()],
      escalate_to: "commonplace-factory",
      outputs: ["chits"],
      environment_faced: []
    }
  end

  defp profile do
    %PodProfile{
      id: "runner-local",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{"postgres" => "16.2"}
    }
  end

  defp data_dir(handle), do: Path.join([handle.pod_home, "workspace", ".commonplace"])

  defp descendants_from_handle(root_pid) do
    do_descendants([root_pid], MapSet.new())
    |> MapSet.delete(root_pid)
    |> Enum.sort()
  end

  defp do_descendants([], found), do: found

  defp do_descendants([pid | rest], found) do
    if MapSet.member?(found, pid) do
      do_descendants(rest, found)
    else
      children_path =
        Path.join(["/proc", Integer.to_string(pid), "task", Integer.to_string(pid), "children"])

      children =
        case File.read(children_path) do
          {:ok, contents} -> contents |> String.split() |> Enum.map(&String.to_integer/1)
          {:error, _reason} -> []
        end

      do_descendants(rest ++ children, MapSet.put(found, pid))
    end
  end

  defp await_file(path), do: await_file(path, System.monotonic_time(:millisecond) + 60_000)

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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 5_000)

  defp eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        receive do
        after
          10 -> eventually(fun, deadline)
        end
      else
        false
      end
    end
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
