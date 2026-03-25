defmodule Commonplace.CLI.Helpers do
  @moduledoc "Shared utility functions for CLI commands."

  @doc """
  Join two path segments, handling empty strings gracefully.

  Unlike `Path.join/2`, this returns the non-empty segment when either is "".
  """
  def join_paths("", path), do: path
  def join_paths(base, ""), do: base
  def join_paths(base, path), do: Path.join(base, path)

  @doc "Returns true if the string is a valid UUID (hex with dashes)."
  def uuid?(str) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, str)
  end
end
