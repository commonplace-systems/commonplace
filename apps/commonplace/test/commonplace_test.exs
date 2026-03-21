defmodule CommonplaceTest do
  use ExUnit.Case
  doctest Commonplace

  test "greets the world" do
    assert Commonplace.hello() == :world
  end
end
