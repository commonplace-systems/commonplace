defmodule Yelixer.IDTest do
  use ExUnit.Case, async: true

  alias Yelixer.ID

  test "creates an ID with client and clock" do
    id = ID.new(1, 0)
    assert id.client == 1
    assert id.clock == 0
  end

  test "compares IDs" do
    assert ID.new(1, 0) == ID.new(1, 0)
    refute ID.new(1, 0) == ID.new(1, 1)
    refute ID.new(1, 0) == ID.new(2, 0)
  end

  test "checks if clock is contained within a range" do
    id = ID.new(1, 5)
    assert ID.contains?(id, 3, 5)
    assert ID.contains?(id, 3, 6)
    assert ID.contains?(id, 3, 7)
    refute ID.contains?(id, 3, 8)
    refute ID.contains?(id, 3, 4)
  end
end
