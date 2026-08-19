defmodule Commonplace.Process.Config do
  @moduledoc """
  Parse and diff __processes.json declarations.

  Each entry declares a process to run, its source, restart strategy,
  and optional ownership of output documents.
  """

  defstruct [
    :name,
    :mode,
    :source,
    :command,
    :args,
    :owns,
    :scope_uuid,
    :fork,
    :identity_uuid,
    :event_log_uuid,
    :capability_cid,
    restart: :permanent,
    depends_on: [],
    env: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          mode: :elixir | :sandbox_exec | :command,
          source: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          restart: :permanent | :transient | :temporary,
          owns: String.t() | nil,
          depends_on: [String.t()],
          env: %{String.t() => String.t()},
          scope_uuid: String.t() | nil,
          fork: :copy | :skip | nil,
          identity_uuid: String.t() | nil,
          event_log_uuid: String.t() | nil,
          capability_cid: binary() | nil
        }

  @doc "Parse a __processes.json map into a list of Config entries."
  def parse(json, scope_uuid \\ nil)

  def parse(json, scope_uuid) when is_map(json) do
    Enum.map(json, fn {name, config} ->
      %__MODULE__{
        name: name,
        mode: parse_mode(config["mode"]),
        source: config["source"],
        command: config["command"],
        args: config["args"] || [],
        restart: parse_restart(config["restart"]),
        owns: config["owns"],
        depends_on: config["depends_on"] || [],
        env: config["env"] || %{},
        scope_uuid: scope_uuid,
        fork: parse_fork(config["fork"])
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

  @doc """
  Returns the effective fork behavior for a process config.

  Explicit fork field takes precedence. Default is :skip for all modes
  except :elixir (stateless in-BEAM modules are safe to copy).
  Use explicit `"fork": "copy"` in __processes.json to opt in.
  """
  def fork_behavior(%__MODULE__{fork: :copy}), do: :copy
  def fork_behavior(%__MODULE__{fork: :skip}), do: :skip
  def fork_behavior(%__MODULE__{mode: :elixir}), do: :copy
  def fork_behavior(%__MODULE__{}), do: :skip

  @doc """
  Filter process configs for fork safety.
  Returns only entries with :copy fork behavior.
  """
  def filter_for_fork(configs) when is_list(configs) do
    Enum.filter(configs, &(fork_behavior(&1) == :copy))
  end

  @doc """
  Filter a raw __processes.json map, removing skip-marked entries.
  Returns a new map with only fork-safe entries.
  """
  def filter_json_for_fork(json) when is_map(json) do
    configs = parse(json)
    safe_names = configs |> filter_for_fork() |> Enum.map(& &1.name) |> MapSet.new()
    Map.filter(json, fn {name, _} -> MapSet.member?(safe_names, name) end)
  end

  defp parse_fork("copy"), do: :copy
  defp parse_fork("skip"), do: :skip
  defp parse_fork(_), do: nil

  defp parse_mode("elixir"), do: :elixir
  defp parse_mode("sandbox-exec"), do: :sandbox_exec
  defp parse_mode("command"), do: :command
  defp parse_mode(_), do: :elixir

  defp parse_restart("permanent"), do: :permanent
  defp parse_restart("transient"), do: :transient
  defp parse_restart("temporary"), do: :temporary
  defp parse_restart(_), do: :permanent
end
