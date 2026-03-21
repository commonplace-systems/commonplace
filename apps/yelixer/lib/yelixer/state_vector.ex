defmodule Yelixer.StateVector do
  @type t :: %__MODULE__{clocks: %{non_neg_integer() => non_neg_integer()}}
  defstruct clocks: %{}

  def new, do: %__MODULE__{}

  def get(%__MODULE__{clocks: clocks}, client) do
    Map.get(clocks, client, 0)
  end

  def set(%__MODULE__{clocks: clocks}, client, clock) do
    %__MODULE__{clocks: Map.put(clocks, client, clock)}
  end

  def advance(%__MODULE__{} = sv, client, clock) do
    if clock > get(sv, client), do: set(sv, client, clock), else: sv
  end

  def diff(%__MODULE__{clocks: remote}, %__MODULE__{clocks: local}) do
    Enum.reduce(remote, %{}, fn {client, remote_clock}, acc ->
      local_clock = Map.get(local, client, 0)

      if remote_clock > local_clock do
        Map.put(acc, client, local_clock)
      else
        acc
      end
    end)
  end
end
