defmodule Yelixer.StateVectorTest do
  use ExUnit.Case, async: true

  alias Yelixer.StateVector

  test "new state vector is empty" do
    sv = StateVector.new()
    assert StateVector.get(sv, 1) == 0
  end

  test "set and get clock for client" do
    sv = StateVector.new() |> StateVector.set(1, 5)
    assert StateVector.get(sv, 1) == 5
    assert StateVector.get(sv, 2) == 0
  end

  test "advance only increases clock" do
    sv = StateVector.new() |> StateVector.set(1, 5)
    sv = StateVector.advance(sv, 1, 3)
    assert StateVector.get(sv, 1) == 5
    sv = StateVector.advance(sv, 1, 10)
    assert StateVector.get(sv, 1) == 10
  end

  test "diff returns missing clocks" do
    local = StateVector.new() |> StateVector.set(1, 5) |> StateVector.set(2, 3)
    remote = StateVector.new() |> StateVector.set(1, 8) |> StateVector.set(3, 2)
    diff = StateVector.diff(remote, local)
    assert diff == %{1 => 5, 3 => 0}
  end
end
