defmodule Commonplace.Sync.CheckoutRegistryForCwdTest do
  @moduledoc """
  CX-voi: `CheckoutRegistry.find_for_cwd/2` reads the persisted
  checkouts.json and returns the nearest enclosing checkout for a
  given cwd (longest `sync_dir` prefix match). Used by MCP presence
  bootstrap to place the agent's .bot file in the sandbox checkout
  it was launched from, rather than always at the workspace root.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Sync.CheckoutRegistry

  setup do
    tmp = Path.join(System.tmp_dir!(), "cp_coreg_cwd_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    config_path = Path.join(tmp, "checkouts.json")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{config_path: config_path, tmp: tmp}
  end

  defp write_config(path, entries) do
    File.write!(path, Jason.encode!(entries))
  end

  describe "find_for_cwd/2" do
    test "returns :none when config file is missing", %{config_path: path} do
      assert :none = CheckoutRegistry.find_for_cwd(path, "/some/where")
    end

    test "returns :none when cwd is outside every checkout", %{config_path: path} do
      write_config(path, [
        %{"sync_dir" => "/home/user/workspace/repo", "uuid" => "u1", "type" => "dir"}
      ])

      assert :none = CheckoutRegistry.find_for_cwd(path, "/unrelated/path")
    end

    test "returns the single matching checkout when cwd is inside it",
         %{config_path: path} do
      write_config(path, [
        %{"sync_dir" => "/home/user/ws/repo", "uuid" => "uuid-repo", "type" => "dir"}
      ])

      assert {:ok, %{uuid: "uuid-repo", sync_dir: "/home/user/ws/repo", type: :dir}} =
               CheckoutRegistry.find_for_cwd(path, "/home/user/ws/repo/subdir/deep")
    end

    test "returns longest-prefix match when multiple checkouts share a prefix",
         %{config_path: path} do
      write_config(path, [
        %{"sync_dir" => "/home/user/ws/repo", "uuid" => "parent", "type" => "dir"},
        %{"sync_dir" => "/home/user/ws/repo/sub", "uuid" => "nested", "type" => "dir"},
        %{"sync_dir" => "/elsewhere", "uuid" => "other", "type" => "dir"}
      ])

      assert {:ok, %{uuid: "nested"}} =
               CheckoutRegistry.find_for_cwd(path, "/home/user/ws/repo/sub/x")
    end

    test "exact sync_dir match counts as a match", %{config_path: path} do
      write_config(path, [
        %{"sync_dir" => "/home/user/ws/repo", "uuid" => "uuid-repo", "type" => "dir"}
      ])

      assert {:ok, %{uuid: "uuid-repo"}} =
               CheckoutRegistry.find_for_cwd(path, "/home/user/ws/repo")
    end

    test "prefix that's only a directory-name suffix is NOT a match",
         %{config_path: path} do
      # /home/user/ws/repo is NOT enclosing for /home/user/ws/repo-backup
      write_config(path, [
        %{"sync_dir" => "/home/user/ws/repo", "uuid" => "u1", "type" => "dir"}
      ])

      assert :none =
               CheckoutRegistry.find_for_cwd(path, "/home/user/ws/repo-backup/thing")
    end

    test "parses type strings into atoms", %{config_path: path} do
      write_config(path, [
        %{"sync_dir" => "/ws", "uuid" => "u", "type" => "file"}
      ])

      assert {:ok, %{type: :file}} = CheckoutRegistry.find_for_cwd(path, "/ws")
    end
  end
end
