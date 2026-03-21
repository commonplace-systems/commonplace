defmodule CommonplaceTest do
  use ExUnit.Case

  test "application starts successfully" do
    assert Process.whereis(Commonplace.Supervisor) != nil
  end
end
