defmodule Commonplace.CLI.Init do
  @moduledoc "Initialize a new commonplace workspace."

  alias Commonplace.CLI

  def run(data_dir, args) do
    if CLI.root_uuid(data_dir) do
      IO.puts("Workspace already initialized at #{data_dir}")
      System.halt(1)
    end

    {opts, rest, invalid} = OptionParser.parse(args, strict: [profile: :string])

    if rest != [] or invalid != [] do
      raise ArgumentError, "usage: commonplace init [--profile default|minimal]"
    end

    profile = parse_profile(Keyword.get(opts, :profile, "default"))

    CLI.ensure_started(data_dir)

    {:ok, %{root_uuid: root_uuid}} =
      Commonplace.Workspace.initialize(data_dir, profile: profile)

    IO.puts("Initialized commonplace workspace at #{data_dir}")
    IO.puts("Root: #{root_uuid}")
  end

  defp parse_profile("default"), do: :default
  defp parse_profile("minimal"), do: :minimal

  defp parse_profile(other) do
    raise ArgumentError,
          "invalid workspace profile #{inspect(other)}; expected default or minimal"
  end
end
