defmodule Commonplace.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Commonplace.Workspace

  describe "root_uuid/0" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_workspace_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      prior = Application.get_env(:commonplace, :data_dir)
      Application.put_env(:commonplace, :data_dir, dir)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:commonplace, :data_dir)
          val -> Application.put_env(:commonplace, :data_dir, val)
        end

        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "reads and trims the root file when present", %{dir: dir} do
      uuid = "11111111-2222-3333-4444-555555555555"
      File.write!(Path.join(dir, "root"), uuid <> "\n")

      assert {:ok, ^uuid} = Workspace.root_uuid()
    end

    test "reads the root file without trailing newline", %{dir: dir} do
      uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      File.write!(Path.join(dir, "root"), uuid)

      assert {:ok, ^uuid} = Workspace.root_uuid()
    end

    test "returns {:error, _} when the root file does not exist", %{dir: _dir} do
      assert {:error, reason} = Workspace.root_uuid()
      assert reason == :enoent
    end
  end
end
