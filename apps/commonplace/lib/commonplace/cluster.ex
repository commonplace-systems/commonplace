defmodule Commonplace.Cluster do
  @moduledoc """
  Cluster configuration for BEAM distribution.

  Uses libcluster with configurable topology. Default: epmd strategy
  with node list from COMMONPLACE_NODES env var (comma-separated).
  """

  @doc "Return libcluster topology config from environment."
  def topology do
    case System.get_env("COMMONPLACE_NODES") do
      nil ->
        []

      nodes_str ->
        nodes =
          nodes_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.to_atom/1)

        [
          commonplace: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: nodes]
          ]
        ]
    end
  end
end
