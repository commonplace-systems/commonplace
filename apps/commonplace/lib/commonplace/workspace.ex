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
end
