defmodule Commonplace.Workspace do
  @moduledoc """
  Workspace discovery helpers — shared by the CLI and MCP entrypoints.

  A commonplace workspace is any directory containing a `.commonplace/`
  subdirectory. `discover/1` walks upward from a starting path looking for
  one, returning the resolved `data_dir` (the `.commonplace/` directory
  itself) and the relative path from that workspace root to the original
  starting directory.
  """

  @workspace_dir ".commonplace"

  @doc """
  Discover the nearest commonplace workspace at or above `start_dir`.

  Returns `{data_dir, relative_path}` if found, or `nil` if no workspace
  exists anywhere on the path to the filesystem root. `data_dir` is the
  absolute path to the `.commonplace/` directory; `relative_path` is the
  portion of `start_dir` below the workspace root (empty string if
  `start_dir` is the workspace root itself).
  """
  @spec discover(Path.t()) :: {Path.t(), String.t()} | nil
  def discover(start_dir) when is_binary(start_dir) do
    do_discover(start_dir, start_dir)
  end

  defp do_discover(current_dir, original_dir) do
    candidate = Path.join(current_dir, @workspace_dir)

    cond do
      File.dir?(candidate) ->
        relative =
          if original_dir == current_dir do
            ""
          else
            Path.relative_to(original_dir, current_dir)
          end

        {candidate, relative}

      current_dir == "/" ->
        nil

      true ->
        do_discover(Path.dirname(current_dir), original_dir)
    end
  end

  @doc """
  Returns the workspace's root schema UUID by reading `<data_dir>/root`.

  `data_dir` is taken from `Application.get_env(:commonplace, :data_dir, "data")`.
  Returns `{:ok, uuid_string}` or `{:error, reason}`.

  Matches the pattern used by the wiki/tree LiveViews' private
  `read_root_uuid/1` helpers — this is the shared version for code that
  lives in the core `commonplace` app (e.g. `ViewActionDispatch`).
  """
  @spec root_uuid() :: {:ok, String.t()} | {:error, term()}
  def root_uuid do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    case File.read(Path.join(data_dir, "root")) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read (or auto-generate) the persistent per-workspace node-id (CX-njf).

  Returns `{:ok, id}` where `id` is a stable string scoped to the
  current `data_dir`. On first call for a workspace, generates a fresh
  UUID, writes it atomically (temp + rename) at `<data_dir>/node_id`
  with mode 0o600, and returns it. Subsequent calls re-read the same
  value.

  This is the prerequisite for derivations like
  `Identity.stable_client_id/1` that previously hashed `{node(), uuid}`
  — `node()` changes across sname renames / IP changes, producing a
  different client_id every restart and reintroducing the state-vector
  bloat CX-6g6 fixed for Presence. A workspace-scoped id is stable
  across BEAM restarts on the same workspace, while still differing
  between separate installs (so two nodes writing to the same logical
  identity get distinct client_ids and Yjs in-memory merge preserves
  both writes).

  Returns `{:error, reason}` only on filesystem errors that prevent
  both reading and creating the file (e.g. data_dir doesn't exist
  yet). Callers that need the id at any cost should fall back to a
  constant when this errors so the system stays writable in degraded
  environments (the bloat is back, but writes don't crash).
  """
  @spec node_id() :: {:ok, String.t()} | {:error, term()}
  def node_id do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    path = Path.join(data_dir, "node_id")

    case File.read(path) do
      {:ok, content} ->
        {:ok, String.trim(content)}

      {:error, :enoent} ->
        write_fresh_node_id(data_dir, path)

      {:error, _} = err ->
        err
    end
  end

  defp write_fresh_node_id(data_dir, path) do
    fresh = UUID.uuid4()
    tmp = Path.join(data_dir, ".node_id.tmp")

    with :ok <- File.write(tmp, fresh, [:write]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path),
         {:ok, content} <- File.read(path) do
      # Re-read after rename so concurrent first-boot races settle on
      # whichever rename landed second (both callers see the same final
      # value).
      {:ok, String.trim(content)}
    end
  end
end
