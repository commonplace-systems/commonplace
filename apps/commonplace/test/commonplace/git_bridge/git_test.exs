defmodule Commonplace.GitBridge.GitTest do
  use ExUnit.Case, async: true

  alias Commonplace.GitBridge.Git

  setup do
    dir = Path.join(System.tmp_dir!(), "gitbridge_git_#{:rand.uniform(1_000_000_000)}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "ensure_repo creates the dir and inits git, checking out the branch", %{dir: dir} do
    assert :ok = Git.ensure_repo(dir, "main")
    assert File.dir?(Path.join(dir, ".git"))
  end

  test "ensure_repo is idempotent", %{dir: dir} do
    assert :ok = Git.ensure_repo(dir, "main")
    assert :ok = Git.ensure_repo(dir, "main")
  end

  test "dirty? reflects working tree state", %{dir: dir} do
    :ok = Git.ensure_repo(dir, "main")
    assert {:ok, false} = Git.dirty?(dir)

    File.write!(Path.join(dir, "a.txt"), "hello")
    assert {:ok, true} = Git.dirty?(dir)
  end

  test "commit_all commits staged changes and returns a sha", %{dir: dir} do
    :ok = Git.ensure_repo(dir, "main")
    File.write!(Path.join(dir, "a.txt"), "hello")

    assert {:ok, sha} = Git.commit_all(dir, authors: ["alice@abc", "bob@def"])
    assert is_binary(sha)
    assert {:ok, false} = Git.dirty?(dir)

    {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: dir)
    assert log =~ "Commonplace-Authors: alice@abc, bob@def"
    {author, 0} = System.cmd("git", ["log", "-1", "--pretty=%an <%ae>"], cd: dir)
    assert String.trim(author) == "commonplace-bridge <bridge@commonplace.local>"
  end

  test "commit_all without authors omits the trailer", %{dir: dir} do
    :ok = Git.ensure_repo(dir, "main")
    File.write!(Path.join(dir, "a.txt"), "hello")
    assert {:ok, _sha} = Git.commit_all(dir)

    {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: dir)
    refute log =~ "Commonplace-Authors"
  end

  test "head_tree_hash returns a stable hash for identical trees", %{dir: dir} do
    :ok = Git.ensure_repo(dir, "main")
    File.write!(Path.join(dir, "a.txt"), "hello")
    {:ok, _} = Git.commit_all(dir)
    assert {:ok, hash} = Git.head_tree_hash(dir)
    assert is_binary(hash)
  end

  test "push to unreachable remote returns an error tuple, never raises", %{dir: dir} do
    :ok = Git.ensure_repo(dir, "main")
    File.write!(Path.join(dir, "a.txt"), "hello")
    {:ok, _} = Git.commit_all(dir)
    {:ok, _} = Git.add_remote(dir, "origin", "/nonexistent/path/repo.git")

    assert {:error, _reason} = Git.push(dir, "origin", "main")
  end

  test "push to a real bare remote succeeds", %{dir: dir} do
    bare_dir = Path.join(System.tmp_dir!(), "gitbridge_bare_#{:rand.uniform(1_000_000_000)}")
    on_exit(fn -> File.rm_rf!(bare_dir) end)
    File.mkdir_p!(bare_dir)
    {_, 0} = System.cmd("git", ["init", "--bare", bare_dir])

    :ok = Git.ensure_repo(dir, "main")
    File.write!(Path.join(dir, "a.txt"), "hello")
    {:ok, _} = Git.commit_all(dir)
    {:ok, _} = Git.add_remote(dir, "origin", bare_dir)

    assert {:ok, _} = Git.push(dir, "origin", "main")

    {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%H"], cd: bare_dir)
    assert String.trim(log) != ""
  end
end
