defmodule Yelixer.ID do
  @type t :: %__MODULE__{client: non_neg_integer(), clock: non_neg_integer()}
  defstruct [:client, :clock]

  def new(client, clock), do: %__MODULE__{client: client, clock: clock}

  def contains?(%__MODULE__{clock: start}, len, clock) do
    clock >= start and clock < start + len
  end
end
