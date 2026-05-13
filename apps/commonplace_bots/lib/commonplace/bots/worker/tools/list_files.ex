defmodule Commonplace.Bots.Worker.Tools.ListFiles do
  @moduledoc """
  `list_files` tool — list direct children of the bot's own
  directory.

  Scoped: a worker can only see its own bot dir. v0 bot
  directories are flat (no nested subdirs), so the tool ignores
  the `path` argument beyond accepting `"/"` or `""` for
  forward-compat with phase-6+ nested layouts. Any non-empty
  non-root path returns `{:error, ...}` rather than walking.

  Returns a JSON array of `{name, type}` entries, sorted by name.
  """

  def name, do: "list_files"

  def definition do
    %{
      "name" => "list_files",
      "description" =>
        "List files in your own bot directory. v0 is flat — the only valid path is '/'.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Directory path inside your bot dir. v0: '/' only."
          }
        }
      }
    }
  end

  def call(state, input) do
    path = normalize(Map.get(input, "path", "/"))

    cond do
      path != "/" ->
        {:error, "list_files: v0 only supports path='/'"}

      true ->
        entries =
          state.entity.children
          |> Map.keys()
          |> Enum.sort()
          |> Enum.map(fn name -> %{"name" => name, "type" => "doc"} end)

        {:ok, Jason.encode!(entries)}
    end
  end

  defp normalize(""), do: "/"
  defp normalize(p) when is_binary(p), do: p
  defp normalize(_), do: "/"
end
