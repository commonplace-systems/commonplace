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
        Application.put_env(:commonplace, :data_dir, prior || "tmp/test_data")

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

  describe "node_id/0 (CX-njf)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_workspace_node_id_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      prior = Application.get_env(:commonplace, :data_dir)
      Application.put_env(:commonplace, :data_dir, dir)

      on_exit(fn ->
        Application.put_env(:commonplace, :data_dir, prior || "tmp/test_data")

        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "auto-generates and persists a node-id on first call", %{dir: dir} do
      refute File.exists?(Path.join(dir, "node_id"))

      assert {:ok, id} = Workspace.node_id()
      assert is_binary(id)
      assert byte_size(id) > 0

      # The file is now present and matches the returned id.
      assert {:ok, contents} = File.read(Path.join(dir, "node_id"))
      assert String.trim(contents) == id
    end

    test "returns the same id on subsequent calls (stable across restarts)",
         %{dir: _dir} do
      assert {:ok, first} = Workspace.node_id()
      assert {:ok, second} = Workspace.node_id()
      assert first == second
    end

    test "reads an existing node-id file without rewriting it", %{dir: dir} do
      preset = "preset-node-id-12345"
      File.write!(Path.join(dir, "node_id"), preset <> "\n")

      assert {:ok, ^preset} = Workspace.node_id()

      # File contents unchanged (we did not auto-rewrite).
      assert {:ok, contents} = File.read(Path.join(dir, "node_id"))
      assert String.trim(contents) == preset
    end

    test "node-id is install-private (mode 0o600)", %{dir: dir} do
      {:ok, _id} = Workspace.node_id()

      stat = File.stat!(Path.join(dir, "node_id"))
      perms = Bitwise.band(stat.mode, 0o777)
      assert perms == 0o600,
             "expected node_id to be 0o600, got #{Integer.to_string(perms, 8)}"
    end
  end
end
