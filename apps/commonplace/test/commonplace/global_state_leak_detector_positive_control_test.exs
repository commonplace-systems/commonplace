defmodule Commonplace.GlobalStateLeakDetectorPositiveControlTest do
  use ExUnit.Case, async: false

  @tag :global_state_leak_detector_positive_control
  test "positive control deliberately leaks :local_write_gate" do
    Application.put_env(:commonplace, :local_write_gate, :cx_0ktk_deliberate_leak)

    assert Application.fetch_env!(:commonplace, :local_write_gate) ==
             :cx_0ktk_deliberate_leak
  end
end
