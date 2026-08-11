defmodule Commonplace.ApplicationBootRefusalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_boot_refusal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "node_signing_public_keys.json"))
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "boot publication failure logs a named reason and deliberately refuses boot" do
    log =
      capture_log(fn ->
        assert_raise RuntimeError,
                     ~r/Commonplace.Application boot refusal: node public-key publication failed/,
                     fn ->
                       Commonplace.Application.publish_public_keys_or_refuse!()
                     end
      end)

    assert log =~ "Commonplace.Application boot refusal"
    assert log =~ "node public-key publication failed: :eisdir"
    assert log =~ "refusing to boot"
    assert log =~ "check COMMONPLACE_DATA_DIR"
  end

  test "successful boot publication remains ok", %{dir: dir} do
    File.rm_rf!(Path.join(dir, "node_signing_public_keys.json"))
    assert :ok = Commonplace.Application.publish_public_keys_or_refuse!()
  end
end
