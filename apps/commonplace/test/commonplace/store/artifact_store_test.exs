defmodule Commonplace.Store.ArtifactStoreTest do
  use ExUnit.Case, async: true

  alias Commonplace.Store.ArtifactStore

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "artifact_store_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)
    %{store: ArtifactStore.new(data_dir), data_dir: data_dir}
  end

  test "streams into the hash-addressed layout and deduplicates", %{
    store: store,
    data_dir: data_dir
  } do
    source = Path.join(data_dir, "source.bin")
    File.write!(source, [<<0, 1, 2>>, :binary.copy(<<255>>, 256_000)])

    assert {:ok, cid} = ArtifactStore.put(store, File.stream!(source, [], 64 * 1024))
    assert {:ok, ^cid} = ArtifactStore.put(store, File.stream!(source, [], 64 * 1024))
    assert ArtifactStore.exists?(store, cid)
    assert Path.join([data_dir, "artifacts", String.slice(cid, 0, 2), cid]) |> File.regular?()
    assert {:ok, stream} = ArtifactStore.get(store, cid)
    assert Enum.to_list(stream) == Enum.to_list(File.stream!(source, [], 64 * 1024))
  end

  test "concurrent puts use unique temps and converge on one blob", %{store: store} do
    bytes = :binary.copy(<<0, 255, 17>>, 100_000)

    results =
      1..8
      |> Task.async_stream(
        fn _ -> ArtifactStore.put(store, Stream.map([bytes], & &1)) end,
        timeout: :infinity,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, cid}] = Enum.uniq(results)
    assert ArtifactStore.exists?(store, cid)
    assert ArtifactStore.temp_paths(store) == []
  end
end
