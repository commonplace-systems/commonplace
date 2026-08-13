defmodule Commonplace.Runner.LauncherTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.{Launcher, PodHandle, PodProfile}

  @canary_name "CX_POD_ENV_CANARY"
  @canary_value "pod-must-not-inherit-this-value"

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

    git!(source_repo, ["init", "--quiet"])
    git!(source_repo, ["config", "user.email", "launcher@example.invalid"])
    git!(source_repo, ["config", "user.name", "Launcher Fixture"])
    git!(source_repo, ["add", "worker.sh", "channel-worker.sh"])
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

  test "pod cannot read a canary injected by its launching BEAM", ctx do
    System.put_env(@canary_name, @canary_value)
    launcher = start_supervised!({Launcher, pods_root: ctx.pods_root})
    handle = launch!(launcher, ctx)
    data_dir = data_dir(handle)

    assert {:ok, canary_result} = await_file(Path.join(data_dir, "environment-canary"))
    assert String.trim(canary_result) == "absent"
    refute canary_result =~ @canary_value
    assert :ok = Launcher.reap(handle)
  end

  test "executes by effect with its five-variable constructed environment", ctx do
    launcher = start_supervised!({Launcher, pods_root: ctx.pods_root})
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

    assert length(environment_names) == 6
    assert environment_names == ~w(COMMONPLACE_DATA_DIR HOME LANG LC_ALL PATH PWD)

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

    launcher = start_supervised!({Launcher, pods_root: ctx.pods_root})
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
    launcher = start_supervised!({Launcher, pods_root: ctx.pods_root})
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
