defmodule Commonplace.GitBridge.SidecarTest do
  use ExUnit.Case, async: true

  alias Commonplace.GitBridge.Sidecar

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_gb_sidecar_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "writes per-doc json + mount.json", %{dir: dir} do
    manifest = %{
      "a.txt" => %{uuid: "uuid-a", type: :text, anchor: <<1, 2, 3>>},
      "sub/b.json" => %{uuid: "uuid-b", type: :map, anchor: nil}
    }

    :ok = Sidecar.write(dir, "mount-uuid", manifest)

    a_json = Jason.decode!(File.read!(Path.join(dir, ".commonplace/a.txt.json")))
    assert a_json == %{"uuid" => "uuid-a", "type" => "text", "anchor" => "010203"}

    b_json = Jason.decode!(File.read!(Path.join(dir, ".commonplace/sub/b.json.json")))
    assert b_json == %{"uuid" => "uuid-b", "type" => "map", "anchor" => nil}

    mount_json = Jason.decode!(File.read!(Path.join(dir, ".commonplace/mount.json")))
    assert mount_json == %{"mount_uuid" => "mount-uuid", "format" => 1}
  end

  test "prunes sidecar entries no longer in the manifest", %{dir: dir} do
    manifest1 = %{"a.txt" => %{uuid: "uuid-a", type: :text, anchor: <<1>>}}
    :ok = Sidecar.write(dir, "mount-uuid", manifest1)
    assert File.exists?(Path.join(dir, ".commonplace/a.txt.json"))

    manifest2 = %{}
    :ok = Sidecar.write(dir, "mount-uuid", manifest2, manifest1)
    refute File.exists?(Path.join(dir, ".commonplace/a.txt.json"))
  end

  test "ensure_gitattributes creates a fresh file", %{dir: dir} do
    :ok = Sidecar.ensure_gitattributes(dir)
    contents = File.read!(Path.join(dir, ".gitattributes"))
    assert contents == ".commonplace/** -diff\n"
  end

  test "ensure_gitattributes appends without duplicating or clobbering", %{dir: dir} do
    File.write!(Path.join(dir, ".gitattributes"), "*.bin binary\n")
    :ok = Sidecar.ensure_gitattributes(dir)
    contents = File.read!(Path.join(dir, ".gitattributes"))
    assert contents == "*.bin binary\n.commonplace/** -diff\n"

    :ok = Sidecar.ensure_gitattributes(dir)
    contents2 = File.read!(Path.join(dir, ".gitattributes"))
    assert contents2 == contents
  end

  test "read_previous_manifest reconstructs rel_path set from .commonplace", %{dir: dir} do
    manifest = %{
      "a.txt" => %{uuid: "uuid-a", type: :text, anchor: <<1, 2>>},
      "sub/b.json" => %{uuid: "uuid-b", type: :map, anchor: nil}
    }

    :ok = Sidecar.write(dir, "mount-uuid", manifest)

    previous = Sidecar.read_previous_manifest(dir)
    assert Map.has_key?(previous, "a.txt")
    assert Map.has_key?(previous, "sub/b.json")
    refute Map.has_key?(previous, "mount.json")
  end

  test "read_previous_manifest returns empty map when no sidecar exists", %{dir: dir} do
    assert Sidecar.read_previous_manifest(dir) == %{}
  end
end
