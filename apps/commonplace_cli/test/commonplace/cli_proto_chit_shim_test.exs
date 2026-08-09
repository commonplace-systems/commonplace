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

    File.write!(emitter, "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$PROTO_CHIT_TEST_FIRED\"\n")
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

  test "tap-through commit leaves git object and ref bytes identical", %{base: base} do
    direct_repo = create_ready_repo(Path.join(base, "direct"))
    tapped_repo = create_ready_repo(Path.join(base, "tapped"))
    emitter = Path.join(base, "success-emitter")
    File.write!(emitter, "#!/bin/sh\nexit 0\n")
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
    assert record["event"]["proto-pin"] == nil
    assert record["event"]["message"] == "wal-me"
    assert record["content-hashes"]["payload.txt"] == sha256("same bytes\n")
    assert {_sha, 0} = System.cmd(@real_git, ["rev-parse", "HEAD"], cd: repo)
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
