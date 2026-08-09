defmodule Commonplace.Trust.DenialCounter do
  @moduledoc """
  The independent, per-BEAM-boot count of local write denials.

  This is deliberately an `:atomics` reference held in `:persistent_term`,
  not a process, telemetry handler, queue, or audit record. The code that
  decides a denial increments it synchronously before emitting telemetry, so
  every downstream audit failure mode remains downstream of this denominator.
  """

  @key {__MODULE__, :boot_counter}

  @doc false
  def init do
    case :persistent_term.get(@key, :missing) do
      :missing ->
        counter = :atomics.new(1, signed: false)
        boot_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        :persistent_term.put(@key, {boot_id, counter})
        :ok

      {_boot_id, _counter} ->
        :ok
    end
  end

  @doc "Increment the independent denial count at the decision site."
  @spec increment() :: non_neg_integer()
  def increment do
    {_boot_id, counter} = state()
    :atomics.add_get(counter, 1, 1)
  end

  @doc "Return the denial count for this BEAM boot."
  @spec value() :: non_neg_integer()
  def value do
    {_boot_id, counter} = state()
    :atomics.get(counter, 1)
  end

  @doc "Return the enclosure shared by every capture-rate figure."
  @spec snapshot() :: %{boot_id: String.t(), emitted: non_neg_integer()}
  def snapshot do
    {boot_id, counter} = state()
    %{boot_id: boot_id, emitted: :atomics.get(counter, 1)}
  end

  @doc "Return the identifier enclosing this boot's counter."
  @spec boot_id() :: String.t()
  def boot_id do
    {boot_id, _counter} = state()
    boot_id
  end

  defp state do
    case :persistent_term.get(@key, :missing) do
      :missing ->
        init()
        :persistent_term.get(@key)

      state ->
        state
    end
  end
end
