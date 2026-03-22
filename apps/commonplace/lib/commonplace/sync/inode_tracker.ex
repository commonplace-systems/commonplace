defmodule Commonplace.Sync.InodeTracker do
  @moduledoc """
  Inode shadow tracking for capturing writes to stale file descriptors.

  When an atomic write (temp+rename) replaces a file, the inode at the
  path changes. If another process has the old file open, its writes go
  to the orphaned old inode — invisible to us.

  Solution: before the atomic write, create a hardlink to the old inode
  in .commonplace-shadow/. A watcher checks for modifications to shadow
  files. When detected, the stale content is read and can be merged via
  CRDT.

  This is Unix-specific — relies on hardlinks preserving inode identity.
  """

  @doc """
  Create a hardlink to a file in the shadow directory.

  The shadow file is named `{dev}-{ino}` to uniquely identify the inode.
  Returns `{:ok, shadow_path}` or `{:error, reason}`.
  """
  def create_shadow(file_path, shadow_dir) do
    case File.stat(file_path) do
      {:ok, %{inode: ino, major_device: dev}} ->
        shadow_name = "#{dev}-#{ino}"
        shadow_path = Path.join(shadow_dir, shadow_name)
        File.mkdir_p!(shadow_dir)

        case File.ln(file_path, shadow_path) do
          :ok -> {:ok, shadow_path}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Track a file: create shadow and record its fingerprint (size + hash).

  Returns `{:ok, shadow_path, fingerprint}`.
  """
  def track(file_path, shadow_dir) do
    {:ok, shadow_path} = create_shadow(file_path, shadow_dir)
    fingerprint = file_fingerprint(shadow_path)
    {:ok, shadow_path, fingerprint}
  end

  @doc """
  Check if a shadow file has been modified since the given fingerprint.

  Compares size and content hash. Returns true if either changed,
  indicating a write to the old inode (stale fd write).
  """
  def stale_write?(shadow_path, original_fingerprint) do
    current = file_fingerprint(shadow_path)
    current != nil and current != original_fingerprint
  end

  @doc "Compute a fingerprint (size + md5) for a file."
  def file_fingerprint(path) do
    case File.read(path) do
      {:ok, content} -> {byte_size(content), :erlang.md5(content)}
      {:error, _} -> nil
    end
  end

  @doc """
  Atomic write with shadow tracking.

  Before replacing the file at `path`:
  1. If the old inode is tracked, create a shadow hardlink
  2. Write new content atomically (temp+fsync+rename)
  3. Track the new inode with the new commit_id
  """
  def atomic_write_with_shadow(path, content, shadow_dir, registry, new_commit_id, doc_uuid) do
    alias Commonplace.Sync.InodeTracker.Registry

    # If file exists and is tracked, shadow the old inode before replacing
    if File.exists?(path) do
      old_inode_key = inode_key(path)

      case Registry.lookup(registry, old_inode_key) do
        {:ok, _mapping} ->
          # Create shadow hardlink to preserve old inode
          case create_shadow(path, shadow_dir) do
            {:ok, shadow_path} ->
              fingerprint = file_fingerprint(shadow_path)
              Registry.shadow(registry, old_inode_key, shadow_path, fingerprint)

            {:error, _} ->
              :ok
          end

        :error ->
          :ok
      end
    end

    # Atomic write (temp + fsync + rename)
    Commonplace.Sync.Export.atomic_write(path, content)

    # Track the new inode
    if File.exists?(path) do
      new_inode_key = inode_key(path)
      Registry.track(registry, new_inode_key, new_commit_id, doc_uuid, path)
    end

    :ok
  end

  @doc "Get the inode key (device, inode) for a file."
  def inode_key(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.inode}
  end

  @doc "Remove a single shadow file."
  def cleanup_shadow(shadow_path) do
    File.rm(shadow_path)
  end

  @doc "Remove all shadow files in a directory."
  def cleanup_all(shadow_dir) do
    case File.ls(shadow_dir) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          File.rm(Path.join(shadow_dir, file))
        end)

      {:error, _} ->
        :ok
    end
  end
end
