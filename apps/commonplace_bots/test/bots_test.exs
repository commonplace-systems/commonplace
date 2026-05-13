defmodule Commonplace.BotsTest do
  use ExUnit.Case

  test "application supervises the WorkerSupervisor" do
    assert Process.whereis(Commonplace.Bots.WorkerSupervisor) != nil
  end
end
