defmodule Commonplace.Process.Config do
  @moduledoc """
  Parse and diff __processes.json declarations.

  Each entry declares a process to run, its source, restart strategy,
  and optional ownership of output documents.
  """

  defstruct [:name, :mode, :source, :owns, restart: :permanent, depends_on: []]

  @type t :: %__MODULE__{
          name: String.t(),
          mode: :elixir | :command,
          source: String.t(),
          restart: :permanent | :transient | :temporary,
          owns: String.t() | nil,
          depends_on: [String.t()]
        }

  @doc "Parse a __processes.json map into a list of Config entries."
  def parse(json) when is_map(json) do
    Enum.map(json, fn {name, config} ->
      %__MODULE__{
        name: name,
        mode: parse_mode(config["mode"]),
        source: config["source"],
        restart: parse_restart(config["restart"]),
        owns: config["owns"],
        depends_on: config["depends_on"] || []
      }
    end)
  end

  @doc "Compute the diff between old and new config lists."
  def diff(old_entries, new_entries) do
    old_map = Map.new(old_entries, &{&1.name, &1})
    new_map = Map.new(new_entries, &{&1.name, &1})

    old_names = MapSet.new(Map.keys(old_map))
    new_names = MapSet.new(Map.keys(new_map))

    added = MapSet.difference(new_names, old_names) |> MapSet.to_list()
    removed = MapSet.difference(old_names, new_names) |> MapSet.to_list()

    changed =
      MapSet.intersection(old_names, new_names)
      |> Enum.filter(fn name -> old_map[name] != new_map[name] end)

    %{added: added, removed: removed, changed: changed}
  end

  defp parse_mode("elixir"), do: :elixir
  defp parse_mode("command"), do: :command
  defp parse_mode(_), do: :elixir

  defp parse_restart("permanent"), do: :permanent
  defp parse_restart("transient"), do: :transient
  defp parse_restart("temporary"), do: :temporary
  defp parse_restart(_), do: :permanent
end
