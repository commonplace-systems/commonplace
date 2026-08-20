defmodule Commonplace.CLI.ProtoChitShimTest do
  use ExUnit.Case, async: true

  @shim Path.expand("../../../../tools/proto-chit/bin/git", __DIR__)
  @real_git "/usr/bin/git"
  @fixed_env [
    {"GIT_AUTHOR_DATE", "2026-08-09T20:00:00Z"},
    {"GIT_COMMITTER_DATE", "2026-08-09T20:00:00Z"}
  ]

  setup do
    base = Path.join(System.tmp_dir!(), "proto_chit_shim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  test "tap firing is observed independently of real git success", %{base: base} do
    repo = create_ready_repo(Path.join(base, "repo"))
    fired = Path.join(base, "emitter-fired")
    emitter = Path.join(base, "emitter")

    File.write!(
      emitter,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$PROTO_CHIT_TEST_FIRED\"\n" <>
        "echo 'proto-chit: tap fired recorded' >&2\n"
    )

    File.chmod!(emitter, 0o755)

    env = shim_env(base, emitter) ++ [{"PROTO_CHIT_TEST_FIRED", fired}] ++ @fixed_env

    assert {_output, 0} =
             System.cmd(@shim, ["commit", "-m", "fired"],
               cd: repo,
               env: env,
               stderr_to_stdout: true
             )

    assert File.read!(fired) =~ "proto-chit emit"
    assert File.read!(fired) =~ "commit -m fired"
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "HEAD"], cd: repo)
  end

  test "a successful tap invokes the emitter again with the witnessed git outcome", %{base: base} do
    repo = create_ready_repo(Path.join(base, "two-invocations-repo"))
    fired = Path.join(base, "two-invocations-fired")
    emitter = Path.join(base, "two-invocations-emitter")

    File.write!(
      emitter,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$PROTO_CHIT_TEST_FIRED\"\n" <>
        "case \"$*\" in\n" <>
        "  *'proto-chit annotate'*) echo 'proto-chit: tap fired witnessed' >&2 ;;\n" <>
        "  *) echo 'proto-chit: tap fired main-ref' >&2 ;;\n" <>
        "esac\n"
    )

    File.chmod!(emitter, 0o755)

    assert {_output, 0} =
             System.cmd(@shim, ["commit", "-m", "two calls"],
               cd: repo,
               env:
                 shim_env(base, emitter) ++
                   [{"PROTO_CHIT_TEST_FIRED", fired}, {"PROTO_CHIT_SYNC_EXCLUDES", ""}] ++
                   @fixed_env,
               stderr_to_stdout: true
             )

    [main_call, annotation_call] = File.read!(fired) |> String.split("\n", trim: true)
    assert main_call =~ "proto-chit emit"
    assert annotation_call =~ "proto-chit annotate"
    assert annotation_call =~ "--main-event-ref main-ref"
    assert annotation_call =~ "--exit-status 0"
    assert annotation_call =~ "commit -m two calls"
  end

  test "the annotation receives and the shim preserves a failed git exit status", %{base: base} do
    repo = create_ready_repo(Path.join(base, "failed-git-repo"))
    git(repo, ["commit", "-m", "parent"])
    fired = Path.join(base, "failed-git-fired")

    emitter =
      write_emitter!(
        base,
        "failed-git-emitter",
        "printf '%s\\n' \"$*\" >> \"$PROTO_CHIT_TEST_FIRED\"\n" <>
          "echo 'proto-chit: tap fired confirmed-ref' >&2\n"
      )

    assert {_output, git_status} =
             System.cmd(@shim, ["commit", "-m", "nothing to commit"],
               cd: repo,
               env: shim_env(base, emitter) ++ [{"PROTO_CHIT_TEST_FIRED", fired}] ++ @fixed_env,
               stderr_to_stdout: true
             )

    assert git_status != 0
    [_, annotation_call] = File.read!(fired) |> String.split("\n", trim: true)
    assert annotation_call =~ "proto-chit annotate"
    assert annotation_call =~ "--exit-status #{git_status}"
  end

  test "exit zero without persist confirmation WALs and still runs git", %{base: base} do
    repo = create_ready_repo(Path.join(base, "unconfirmed-repo"))
    state_dir = Path.join(base, "unconfirmed-state")
    emitter = write_emitter!(base, "unconfirmed-emitter", "echo 'booting emitter' >&2\nexit 0\n")

    assert {_output, 0} =
             System.cmd(@shim, ["commit", "-m", "unconfirmed"],
               cd: repo,
               env: shim_env(state_dir, emitter) ++ @fixed_env,
               stderr_to_stdout: true
             )

    assert [record] = read_wal(state_dir)
    assert record["failure"] == "emitter-exit-0-unconfirmed"
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "HEAD"], cd: repo)
  end

  test "exit zero with persist confirmation does not WAL and still runs git", %{base: base} do
    repo = create_ready_repo(Path.join(base, "confirmed-repo"))
    state_dir = Path.join(base, "confirmed-state")

    emitter =
      write_emitter!(
        base,
        "confirmed-emitter",
        "echo 'proto-chit: tap fired abc123' >&2\nexit 0\n"
      )

    assert {_output, 0} =
             System.cmd(@shim, ["commit", "-m", "confirmed"],
               cd: repo,
               env: shim_env(state_dir, emitter) ++ @fixed_env,
               stderr_to_stdout: true
             )

    refute File.exists?(Path.join(state_dir, "events.wal.ndjson"))
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "HEAD"], cd: repo)
  end

  test "a failed annotation gets its own replayable WAL envelope", %{base: base} do
    repo = create_ready_repo(Path.join(base, "annotation-wal-repo"))
    state_dir = Path.join(base, "annotation-wal-state")

    emitter =
      write_emitter!(
        base,
        "annotation-failing-emitter",
        "case \"$*\" in\n" <>
          "  *'proto-chit annotate'*) exit 4 ;;\n" <>
          "  *) echo 'proto-chit: tap fired main-for-annotation-wal' >&2 ;;\n" <>
          "esac\n"
      )

    assert {_output, 0} =
             System.cmd(@shim, ["commit", "-m", "annotation wal"],
               cd: repo,
               env: shim_env(state_dir, emitter) ++ @fixed_env,
               stderr_to_stdout: true
             )

    assert [record] = read_wal(state_dir)
    assert record["failure"] == "annotation-emitter-exit-4"
    assert record["replay-grade"] == "append-at-replay"
    assert record["event"]["kind"] == "post-exec"
    assert record["event"]["main-event-ref"] == "main-for-annotation-wal"
    assert record["event"]["exit-status"] == 0

    assert record["event"]["resulting-git-sha"] ==
             git(repo, ["rev-parse", "HEAD"]) |> String.trim()

    assert record["event"]["message"] == "annotation wal"
  end

  test "nonzero emitter exit WALs and still runs git", %{base: base} do
    repo = create_ready_repo(Path.join(base, "nonzero-repo"))
    state_dir = Path.join(base, "nonzero-state")
    emitter = write_emitter!(base, "nonzero-emitter", "exit 3\n")

    assert {_output, 0} =
             System.cmd(@shim, ["commit", "-m", "nonzero"],
               cd: repo,
               env: shim_env(state_dir, emitter) ++ @fixed_env,
               stderr_to_stdout: true
             )

    assert [record] = read_wal(state_dir)
    assert record["failure"] == "emitter-exit-3"
    assert record["post-exec"]["disposition"] == "skipped-main-emission-failed"
    assert record["post-exec"]["exit-status"] == 0

    assert record["post-exec"]["resulting-git-sha"] ==
             git(repo, ["rev-parse", "HEAD"]) |> String.trim()

    assert record["post-exec"]["message"] == "nonzero"
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "HEAD"], cd: repo)
  end

  test "emitter output remains loud on stderr and ordered", %{base: base} do
    repo = create_ready_repo(Path.join(base, "ordered-repo"))
    state_dir = Path.join(base, "ordered-state")

    emitter =
      write_emitter!(
        base,
        "ordered-emitter",
        "echo 'emitter marker one'\necho 'emitter marker two' >&2\n" <>
          "echo 'proto-chit: tap fired ordered' >&2\nexit 0\n"
      )

    {stderr, status} = shim_stderr(repo, state_dir, ["commit", "-m", "ordered"], emitter)

    assert status == 0
    assert stderr =~ "emitter marker one\nemitter marker two\n"
  end

  test "PROTO_CHIT_SYNC_EXCLUDES becomes one --sync-exclude pair per name", %{base: base} do
    repo = create_ready_repo(Path.join(base, "excludes-repo"))
    argv = recording_emitter_argv(base, repo, [{"PROTO_CHIT_SYNC_EXCLUDES", "bd,chat"}])

    assert argv =~ "--sync-exclude bd --sync-exclude chat"
    # The git argv still arrives last, after the `--` separator, unchanged.
    assert argv =~ ~r/-- commit -m excluded$/
  end

  test "set-but-empty PROTO_CHIT_SYNC_EXCLUDES declares defaults-only scope", %{base: base} do
    repo = create_ready_repo(Path.join(base, "empty-excludes-repo"))
    argv = recording_emitter_argv(base, repo, [{"PROTO_CHIT_SYNC_EXCLUDES", ""}])

    assert argv =~ "--declare-empty-sync-excludes"
    refute argv =~ "--sync-exclude"
    assert argv =~ ~r/-- commit -m excluded$/
  end

  test "unset PROTO_CHIT_SYNC_EXCLUDES sends no scope declaration", %{base: base} do
    repo = create_ready_repo(Path.join(base, "no-excludes-repo"))
    argv = recording_emitter_argv(base, repo, [])

    refute argv =~ "--sync-exclude"
    refute argv =~ "--declare-empty-sync-excludes"
    assert argv =~ ~r/-- commit -m excluded$/
  end

  test "undeclared scope refusal WALs intent loudly and still runs git", %{base: base} do
    repo = create_ready_repo(Path.join(base, "refused-scope-repo"))
    state_dir = Path.join(base, "refused-scope-state")

    emitter =
      write_emitter!(
        base,
        "scope-refusing-emitter",
        "echo 'proto-chit: emission failed: sync scope is undeclared; set " <>
          "PROTO_CHIT_SYNC_EXCLUDES (set-but-empty declares defaults-only), repeat " <>
          "--sync-exclude NAME, or pass --declare-empty-sync-excludes' >&2\nexit 1\n"
      )

    assert {output, 0} =
             System.cmd(@shim, ["commit", "-m", "scope-refused"],
               cd: repo,
               env: shim_env(state_dir, emitter) ++ @fixed_env,
               stderr_to_stdout: true
             )

    assert output =~ "PROTO_CHIT_SYNC_EXCLUDES"
    assert output =~ "--sync-exclude"
    assert output =~ "--declare-empty-sync-excludes"
    assert [record] = read_wal(state_dir)
    assert record["failure"] == "emitter-exit-1"
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "HEAD"], cd: repo)
  end

  # Drives the real shim with an emitter that records the argv it was handed.
  defp recording_emitter_argv(base, repo, extra_env) do
    unique = System.unique_integer([:positive])
    fired = Path.join(base, "argv-#{unique}")
    emitter = Path.join(base, "argv-emitter-#{unique}")

    File.write!(
      emitter,
      "#!/bin/sh\ncase \"$*\" in *'proto-chit emit'*) " <>
        "printf '%s\\n' \"$*\" > \"$PROTO_CHIT_TEST_FIRED\" ;; esac\n" <>
        "echo 'proto-chit: tap fired argv' >&2\n"
    )

    File.chmod!(emitter, 0o755)

    env =
      shim_env(base, emitter) ++ [{"PROTO_CHIT_TEST_FIRED", fired}] ++ @fixed_env ++ extra_env

    {command, args} =
      if {"PROTO_CHIT_SYNC_EXCLUDES", ""} in extra_env do
        {"/usr/bin/env", ["PROTO_CHIT_SYNC_EXCLUDES=", @shim, "commit", "-m", "excluded"]}
      else
        {@shim, ["commit", "-m", "excluded"]}
      end

    assert {_output, 0} =
             System.cmd(command, args,
               cd: repo,
               env: env,
               stderr_to_stdout: true
             )

    String.trim(File.read!(fired))
  end

  test "tap-through commit leaves git object and ref bytes identical", %{base: base} do
    direct_repo = create_ready_repo(Path.join(base, "direct"))
    tapped_repo = create_ready_repo(Path.join(base, "tapped"))
    emitter = Path.join(base, "success-emitter")
    File.write!(emitter, "#!/bin/sh\necho 'proto-chit: tap fired identical' >&2\nexit 0\n")
    File.chmod!(emitter, 0o755)

    assert {_output, 0} =
             System.cmd(@real_git, ["commit", "-m", "byte-identical"],
               cd: direct_repo,
               env: @fixed_env,
               stderr_to_stdout: true
             )

    assert {_output, 0} =
             System.cmd(@shim, ["commit", "-m", "byte-identical"],
               cd: tapped_repo,
               env: shim_env(base, emitter) ++ @fixed_env,
               stderr_to_stdout: true
             )

    assert git_bytes(direct_repo) == git_bytes(tapped_repo)
  end

  test "unreachable gated emitter WALs a hashed intent and still runs git", %{base: base} do
    repo = create_ready_repo(Path.join(base, "wal-repo"))
    state_dir = Path.join(base, "wal-state")
    env = shim_env(state_dir, "/bin/false") ++ @fixed_env

    assert {output, 0} =
             System.cmd(@shim, ["commit", "-m", "wal-me"],
               cd: repo,
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "unsigned intent WALed"
    wal_path = Path.join(state_dir, "events.wal.ndjson")
    assert File.regular?(wal_path)

    [record] =
      wal_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert record["status"] == "pending"
    assert record["replay-grade"] == "pin-cut-at-replay"
    assert record["wal-version"] == 2

    assert record["authentication"] == %{
             "state" => "unsigned",
             "reason" => "deployment-signer-unavailable"
           }

    assert record["event"]["proto-pin"] == nil
    assert record["event"]["message"] == "wal-me"
    assert record["content-hashes"]["payload.txt"] == sha256("same bytes\n")
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "HEAD"], cd: repo)
  end

  test "a non-empty WAL is reported loudly on stderr by an untapped read verb", %{base: base} do
    repo = create_ready_repo(Path.join(base, "loud-repo"))
    state_dir = Path.join(base, "loud-state")
    write_wal!(state_dir, [wal_row(hours_ago(50)), wal_row(hours_ago(2))])

    {stderr, status} = shim_stderr(repo, state_dir, ["status"])

    assert status == 0
    assert [line] = Regex.run(~r/^proto-chit: .*$/m, stderr)
    assert line =~ ~r/^proto-chit: 2 pending intent envelopes, oldest 2d$/
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "--is-inside-work-tree"], cd: repo)
  end

  test "no WAL means no loud line, and the capture proves it can see one", %{base: base} do
    repo = create_ready_repo(Path.join(base, "quiet-repo"))
    state_dir = Path.join(base, "quiet-state")
    File.mkdir_p!(state_dir)

    {quiet_stderr, quiet_status} = shim_stderr(repo, state_dir, ["status"])

    assert quiet_status == 0
    refute quiet_stderr =~ "proto-chit:"

    # Positive control on the same capture path, same test run: the only change
    # is the WAL, so a silent capture cannot be mistaken for a silent shim.
    write_wal!(state_dir, [wal_row(hours_ago(2))])
    {loud_stderr, loud_status} = shim_stderr(repo, state_dir, ["status"])

    assert loud_status == 0
    assert loud_stderr =~ ~r/^proto-chit: 1 pending intent envelopes, oldest 2h$/m
  end

  test "a malformed WAL still reports the count with an unknown age", %{base: base} do
    repo = create_ready_repo(Path.join(base, "garbage-repo"))
    state_dir = Path.join(base, "garbage-state")
    write_wal!(state_dir, ["}{ not json at all", wal_row(hours_ago(2))])

    {stderr, status} = shim_stderr(repo, state_dir, ["status"])

    assert status == 0
    assert stderr =~ ~r/^proto-chit: 2 pending intent envelopes, oldest unknown$/m
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "--is-inside-work-tree"], cd: repo)
  end

  # Runs the shim with stdout discarded, so anything captured here reached
  # stderr and nothing the shim adds could have polluted git's stdout.
  defp shim_stderr(repo, state_dir, args) do
    shim_stderr(repo, state_dir, args, "/bin/false")
  end

  defp shim_stderr(repo, state_dir, args, emitter) do
    System.cmd("/bin/sh", ["-c", ~s(exec "$0" "$@" 2>&1 1>/dev/null), @shim | args],
      cd: repo,
      env: shim_env(state_dir, emitter) ++ @fixed_env
    )
  end

  defp write_emitter!(base, name, body) do
    emitter = Path.join(base, name)
    File.write!(emitter, "#!/bin/sh\n" <> body)
    File.chmod!(emitter, 0o755)
    emitter
  end

  defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

  # Mirrors the recording-time field proto-chit-wal writes: an ISO-8601 UTC
  # `recorded-at` on a compact single-line JSON object.
  defp wal_row(%DateTime{} = recorded_at) do
    Jason.encode!(%{
      "wal-version" => 1,
      "status" => "pending",
      "replay-grade" => "pin-cut-at-replay",
      "failure" => "emitter-exit-1",
      "recorded-at" => String.replace_suffix(DateTime.to_iso8601(recorded_at), "Z", "+00:00"),
      "git-argv" => ["commit", "-m", "backdated"],
      "content-hashes" => %{},
      "event" => %{"verb" => "commit", "proto-pin" => nil}
    })
  end

  defp write_wal!(state_dir, rows) do
    File.mkdir_p!(state_dir)
    File.write!(Path.join(state_dir, "events.wal.ndjson"), Enum.map(rows, &(&1 <> "\n")))
  end

  defp read_wal(state_dir) do
    state_dir
    |> Path.join("events.wal.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp create_ready_repo(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "payload.txt"), "same bytes\n")
    assert {_, 0} = System.cmd(@real_git, ["init", "-b", "main"], cd: path)
    assert {_, 0} = System.cmd(@real_git, ["config", "user.name", "Proto Chit Test"], cd: path)

    assert {_, 0} =
             System.cmd(@real_git, ["config", "user.email", "proto@example.invalid"], cd: path)

    assert {_, 0} = System.cmd(@real_git, ["add", "payload.txt"], cd: path)
    path
  end

  defp shim_env(state_dir, emitter) do
    [
      {"PROTO_CHIT_REAL_GIT", @real_git},
      {"PROTO_CHIT_COMMONPLACE", emitter},
      {"PROTO_CHIT_DATA_DIR", Path.join(state_dir, "fixture-store")},
      {"PROTO_CHIT_EVENT_LOG_UUID", "fixture-event-log"},
      {"PROTO_CHIT_STATE_DIR", state_dir}
    ]
  end

  defp git_bytes(repo) do
    %{
      head: git(repo, ["rev-parse", "HEAD"]),
      commit: git(repo, ["cat-file", "commit", "HEAD"]),
      tree_id: git(repo, ["rev-parse", "HEAD^{tree}"]),
      tree: git(repo, ["cat-file", "tree", "HEAD^{tree}"]),
      ref: File.read!(Path.join(repo, ".git/refs/heads/main"))
    }
  end

  defp git(repo, args) do
    {bytes, 0} = System.cmd(@real_git, args, cd: repo)
    bytes
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
