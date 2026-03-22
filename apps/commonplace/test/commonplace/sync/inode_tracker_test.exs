defmodule Commonplace.Sync.InodeTrackerTest do
  @moduledoc """
  Tests for inode shadow tracking.

  When atomic writes replace a file (temp+rename), the old inode becomes
  orphaned. If another process has the old file open, its writes go to
  the orphaned inode. The shadow tracker creates hardlinks to preserve
  old inodes and watches for writes to them.
  """
  use ExUnit.Case

  alias Commonplace.Sync.InodeTracker

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_inode_test_#{:rand.uniform(1_000_000)}")
    shadow_dir = Path.join(dir, ".commonplace-shadow")
    File.mkdir_p!(dir)
    File.mkdir_p!(shadow_dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, shadow_dir: shadow_dir}
  end

  describe "create_shadow/3" do
    test "creates a hardlink to the file in shadow dir", %{dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "original")

      {:ok, shadow_path} = InodeTracker.create_shadow(path, shadow_dir)

      assert File.exists?(shadow_path)
      assert File.read!(shadow_path) == "original"

      # Verify it's a hardlink (same inode)
      {:ok, orig_stat} = File.stat(path)
      {:ok, shadow_stat} = File.stat(shadow_path)
      assert orig_stat.inode == shadow_stat.inode
    end

    test "shadow name encodes dev and inode", %{dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "content")

      {:ok, shadow_path} = InodeTracker.create_shadow(path, shadow_dir)

      basename = Path.basename(shadow_path)
      # Should contain dev-ino pattern
      assert String.contains?(basename, "-")
    end
  end

  describe "detect_stale_write/2" do
    test "detects when a shadow file has been modified", %{dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "original")

      {:ok, shadow_path} = InodeTracker.create_shadow(path, shadow_dir)
      original_fingerprint = File.stat!(shadow_path).mtime

      # Simulate atomic write (new content at same path, different inode)
      tmp = Path.join(dir, ".file.txt.tmp")
      File.write!(tmp, "new content")
      File.rename!(tmp, path)

      # Now write to the OLD inode via the shadow hardlink
      # (simulating a process with a stale fd)
      File.write!(shadow_path, "stale fd write")

      # Detect the stale write
      assert InodeTracker.stale_write?(shadow_path, original_fingerprint)
    end

    test "no stale write when shadow unchanged", %{dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "original")

      {:ok, shadow_path, fingerprint} = InodeTracker.track(path, shadow_dir)

      refute InodeTracker.stale_write?(shadow_path, fingerprint)
    end
  end

  describe "shadow lifecycle" do
    test "cleanup removes shadow files", %{dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "content")

      {:ok, shadow_path} = InodeTracker.create_shadow(path, shadow_dir)
      assert File.exists?(shadow_path)

      InodeTracker.cleanup_shadow(shadow_path)
      refute File.exists?(shadow_path)
    end

    test "cleanup_all removes all shadows in directory", %{dir: dir, shadow_dir: shadow_dir} do
      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")

      {:ok, _} = InodeTracker.create_shadow(Path.join(dir, "a.txt"), shadow_dir)
      {:ok, _} = InodeTracker.create_shadow(Path.join(dir, "b.txt"), shadow_dir)

      assert length(File.ls!(shadow_dir)) == 2

      InodeTracker.cleanup_all(shadow_dir)
      assert File.ls!(shadow_dir) == []
    end
  end

  describe "track_and_check" do
    test "full flow: create shadow, atomic write, detect stale write", %{dir: dir, shadow_dir: shadow_dir} do
      path = Path.join(dir, "tracked.txt")
      File.write!(path, "v1")

      # Track the file before atomic write
      {:ok, shadow_path, mtime} = InodeTracker.track(path, shadow_dir)

      # Simulate another process opening the file (via shadow hardlink)
      {:ok, stale_fd} = File.open(shadow_path, [:write, :append])

      # Atomic write replaces the file
      tmp = Path.join(dir, ".tracked.txt.tmp")
      File.write!(tmp, "v2")
      File.rename!(tmp, path)

      # The stale fd writes to the old inode
      IO.binwrite(stale_fd, "\nstale addition")
      File.close(stale_fd)

      # Detect the stale write
      assert InodeTracker.stale_write?(shadow_path, mtime)

      # Read the stale content
      stale_content = File.read!(shadow_path)
      assert String.contains?(stale_content, "stale addition")

      # Current file has the atomic write
      assert File.read!(path) == "v2"

      # Cleanup
      InodeTracker.cleanup_shadow(shadow_path)
    end
  end
end
