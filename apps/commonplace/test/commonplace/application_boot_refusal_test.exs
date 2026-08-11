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

  test "invalid local read gate refuses application start before supervisor children" do
    old_gate = Application.fetch_env(:commonplace, :local_read_gate)
    Application.put_env(:commonplace, :local_read_gate, "invalid-s12-boot-value")

    on_exit(fn ->
      case old_gate do
        {:ok, value} -> Application.put_env(:commonplace, :local_read_gate, value)
        :error -> Application.delete_env(:commonplace, :local_read_gate)
      end
    end)

    assert_raise ArgumentError,
                 "Commonplace.Trust local_read_gate refusal: invalid value " <>
                   "\"invalid-s12-boot-value\"; valid values: permissive | dry_run | enforce",
                 fn -> Commonplace.Application.start(:normal, []) end
  end
end
