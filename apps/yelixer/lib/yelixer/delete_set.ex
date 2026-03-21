defmodule Yelixer.DeleteSet do
  @type range :: {non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{clients: %{non_neg_integer() => [range()]}}
  defstruct clients: %{}

  def new, do: %__MODULE__{}

  def insert(%__MODULE__{clients: clients}, client, clock, len) do
    ranges = Map.get(clients, client, [])
    ranges = add_range(ranges, {clock, clock + len})
    %__MODULE__{clients: Map.put(clients, client, ranges)}
  end

  def deleted?(%__MODULE__{clients: clients}, client, clock) do
    clients
    |> Map.get(client, [])
    |> Enum.any?(fn {start, stop} -> clock >= start and clock < stop end)
  end

  def merge(%__MODULE__{clients: c1}, %__MODULE__{clients: c2}) do
    merged =
      Map.merge(c1, c2, fn _client, ranges1, ranges2 ->
        Enum.reduce(ranges2, ranges1, fn range, acc -> add_range(acc, range) end)
      end)

    %__MODULE__{clients: merged}
  end

  defp add_range(ranges, {new_start, new_end}) do
    {overlapping, rest} =
      Enum.split_with(ranges, fn {s, e} ->
        s <= new_end and new_start <= e
      end)

    merged_start = Enum.reduce(overlapping, new_start, fn {s, _}, acc -> min(s, acc) end)
    merged_end = Enum.reduce(overlapping, new_end, fn {_, e}, acc -> max(e, acc) end)

    [{merged_start, merged_end} | rest]
    |> Enum.sort()
  end
end
