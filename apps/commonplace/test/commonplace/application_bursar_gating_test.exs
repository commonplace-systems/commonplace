defmodule Commonplace.ApplicationBursarGatingTest do
  @moduledoc """
  Move #4 (CX-tdkq.7, decision B8): bursar-on-boot is DOUBLE-GATED like
  orchestrator-on-boot — explicit opt-in config AND a resolvable
  workspace root. The Bursar is the cluster's lock authority; it rides
  the serve node's single-owner designation, so nothing except a
  deliberately-configured embedder (`commonplace serve`) may start it.
  Test runs, web, MCP, and bare `mix run` nodes stay bursar-free.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Green.Bursar

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bursar_gate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      Application.delete_env(:commonplace, :bursar_on_boot)
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp write_root!(dir) do
    root_uuid = UUID.uuid4()
    File.write!(Path.join(dir, "root"), root_uuid)
    root_uuid
  end

  test "flag false → no child" do
    Application.put_env(:commonplace, :bursar_on_boot, false)
    assert Commonplace.Application.bursar_children() == []
  end

  test "flag absent → no child (default off)" do
    assert Commonplace.Application.bursar_children() == []
  end

  test "flag true but no workspace root → no child" do
    Application.put_env(:commonplace, :bursar_on_boot, true)
    assert Commonplace.Application.bursar_children() == []
  end

  test "flag true + workspace root → named permanent child spec", %{dir: dir} do
    root_uuid = write_root!(dir)
    Application.put_env(:commonplace, :bursar_on_boot, true)

    assert [spec] = Commonplace.Application.bursar_children()
    assert spec.id == Bursar
    assert spec.restart == :permanent
    {Bursar, :start_link, [opts]} = spec.start
    assert opts[:root_uuid] == root_uuid
    assert opts[:name] == Bursar
  end
end
