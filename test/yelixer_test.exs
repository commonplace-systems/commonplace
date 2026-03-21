defmodule YelixerTest do
  use ExUnit.Case
  doctest Yelixer

  test "greets the world" do
    assert Yelixer.hello() == :world
  end
end
