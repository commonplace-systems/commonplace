defmodule Commonplace.Sync.BinaryArtifactRefTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{ArtifactStore, Commit, CommitStore}
  alias Commonplace.Sync.{BinaryClassifier, BinaryWriteBack, Export, Watcher}
  alias Commonplace.Tree.Schema

  setup do
    base = Path.join(System.tmp_dir!(), "binary_ref_#{System.unique_integer([:positive])}")
    data_dir = Path.join(base, "data")
    watch_dir = Path.join(base, "watch")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(watch_dir)
    store = :"binary_ref_store_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store})
    artifact_store = ArtifactStore.new(data_dir)

    root_uuid = UUID.uuid4()
    root = Schema.new_schema()
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root), nil)

    on_exit(fn -> File.rm_rf!(base) end)

    %{store: store, artifact_store: artifact_store, watch_dir: watch_dir, root_uuid: root_uuid}
  end

  test "ROUND-TRIP FIDELITY: both fact routes import and write back byte-identically",
       %{store: store, artifact_store: artifacts, watch_dir: dir, root_uuid: root} do
    invalid_path = Path.join(dir, "measured.dat")
    declared_path = Path.join(dir, "declared.cub")
    invalid_bytes = <<0xFF, 0xFE, 0, 1, 2, 3>>
    declared_bytes = "valid UTF-8 is still binary by declaration\n"
    File.write!(invalid_path, invalid_bytes)
    File.write!(declared_path, declared_bytes)
    File.chmod!(invalid_path, 0o640)
    File.chmod!(declared_path, 0o600)

    report = Watcher.sync_recursive(root, dir, store, artifact_store: artifacts)
    assert report.skipped == []
    assert report.landed == Enum.sort([declared_path, invalid_path])

    root_doc = load_doc(root, store)

    for {name, bytes, route, mode} <- [
          {"measured.dat", invalid_bytes, :invalid_utf8, 0o640},
          {"declared.cub", declared_bytes, :declared_extension, 0o600}
        ] do
      {:ok, entry} = Schema.get_entry(root_doc, name)
      envelope = entry.node_id |> load_doc(store) |> ContentType.get_content()
      assert envelope.classified_by == route
      assert envelope.size == byte_size(bytes)
      assert envelope.mode == mode
      assert envelope.cid == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      output = Path.join(dir, "out-#{name}")
      assert :ok = BinaryWriteBack.write(artifacts, envelope, output)
      assert File.read!(output) == bytes
      assert Bitwise.band(File.stat!(output).mode, 0o777) == mode
    end
  end

  test "THE RS CORRUPTION RED: fetch failure refuses loudly and leaves prior file intact",
       %{artifact_store: artifacts, watch_dir: dir, store: store, root_uuid: root} do
    path = Path.join(dir, "kept.bin")
    File.write!(path, "prior bytes stay intact")
    missing = String.duplicate("a", 64)

    file_uuid = UUID.uuid4()

    doc =
      Yelixer.Doc.new(client_id: 77)
      |> ContentType.create(:binary, "kept.bin")
      |> ContentType.put_binary_envelope(binary_envelope(missing))

    CommitStore.create_commit(store, file_uuid, Yelixer.Encoding.encode_update(doc), nil)

    root_doc = root |> load_doc(store) |> Schema.add_file("kept.bin", file_uuid)
    CommitStore.create_chained_commit(store, root, Yelixer.Encoding.encode_update(root_doc))

    log =
      capture_log(fn ->
        Export.export(root, dir, store, artifact_store: artifacts)
      end)

    assert log =~ "artifact_fetch_failed"
    assert log =~ path
    assert File.read!(path) == "prior bytes stay intact"
  end

  test "MEMORY: declared large binary import uses the streaming CAS path",
       %{store: store, artifact_store: artifacts, watch_dir: dir, root_uuid: root} do
    path = Path.join(dir, "large.cub")
    chunk = :binary.copy(<<0, 1, 2, 3>>, 16 * 1024)
    io = File.open!(path, [:write, :binary])
    Enum.each(1..256, fn _ -> IO.binwrite(io, chunk) end)
    File.close(io)
    assert File.stat!(path).size == 16 * 1024 * 1024

    assert %{landed: [^path], skipped: []} =
             Watcher.sync_recursive(root, dir, store, artifact_store: artifacts)

    {:ok, entry} = root |> load_doc(store) |> Schema.get_entry("large.cub")
    envelope = entry.node_id |> load_doc(store) |> ContentType.get_content()
    assert envelope.size == 16 * 1024 * 1024
    assert ArtifactStore.exists?(artifacts, envelope.cid)
  end

  test "MERGE: concurrent envelopes converge atomically and both blobs remain reachable",
       %{artifact_store: artifacts, store: store} do
    {:ok, left_cid} = ArtifactStore.put(artifacts, ["left bytes"])
    {:ok, right_cid} = ArtifactStore.put(artifacts, ["right bytes"])

    base = Yelixer.Doc.new(client_id: 1) |> ContentType.create(:binary, "asset.bin")
    base_update = Yelixer.Encoding.encode_update(base)
    left = apply_update(Yelixer.Doc.new(client_id: 2), base_update)
    right = apply_update(Yelixer.Doc.new(client_id: 3), base_update)
    left = ContentType.put_binary_envelope(left, binary_envelope(left_cid, 10))
    right = ContentType.put_binary_envelope(right, binary_envelope(right_cid, 11))
    left_update = Yelixer.Encoding.encode_update(left)
    right_update = Yelixer.Encoding.encode_update(right)

    doc_uuid = UUID.uuid4()
    base_commit = CommitStore.create_commit(store, doc_uuid, base_update, nil)
    left_commit = CommitStore.create_commit(store, doc_uuid, left_update, base_commit.id)
    right_commit = Commit.new(doc_uuid, right_update, base_commit.id, %{kind: :regular})
    assert :ok = CommitStore.import_commit(store, right_commit, validator: fn _ -> :ok end)

    left = apply_update(left, right_update)
    right = apply_update(right, left_update)

    assert ContentType.get_content(left) == ContentType.get_content(right)

    assert ContentType.get_content(left) in [
             binary_envelope(left_cid, 10),
             binary_envelope(right_cid, 11)
           ]

    assert ArtifactStore.exists?(artifacts, left_cid)
    assert ArtifactStore.exists?(artifacts, right_cid)

    history_ids = CommitStore.all_commit_ids_for_doc(store, doc_uuid)
    assert MapSet.member?(history_ids, left_commit.id)
    assert MapSet.member?(history_ids, right_commit.id)
  end

  test "NO-SNIFF PIN: valid UTF-8 with an undeclared extension imports as text",
       %{store: store, artifact_store: artifacts, watch_dir: dir, root_uuid: root} do
    path = Path.join(dir, "looks-opaque.custom")
    bytes = "AAECA/+/ definitely not sniffed as encoded bytes"
    File.write!(path, bytes)

    assert :text == BinaryClassifier.classify(path)

    assert %{landed: [^path], skipped: []} =
             Watcher.sync_recursive(root, dir, store, artifact_store: artifacts)

    {:ok, entry} = root |> load_doc(store) |> Schema.get_entry("looks-opaque.custom")
    doc = load_doc(entry.node_id, store)
    assert ContentType.get_type(doc) == :text
    assert ContentType.get_content(doc) == bytes
  end

  test "the carried declaration is exact, excludes svg, and includes cub" do
    assert BinaryClassifier.declared_extensions() == ~w(
             png jpg jpeg gif bmp ico webp tiff tif
             mp3 wav flac aac ogg m4a wma
             mp4 avi mkv mov wmv flv webm
             zip tar gz bz2 xz 7z rar
             pdf doc docx xls xlsx ppt pptx odt ods odp
             dll so dylib app
             wasm class pyc pyo o a lib
             ttf otf woff woff2 eot
             db sqlite sqlite3 cub
           )

    refute "svg" in BinaryClassifier.declared_extensions()
  end

  defp load_doc(uuid, store) when is_binary(uuid) and is_atom(store) do
    load_doc_from_store(store, uuid)
  end

  defp load_doc_from_store(store, uuid) do
    {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, uuid, mint: false)
    doc
  end

  defp apply_update(doc, update) do
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, update)
    doc
  end

  defp binary_envelope(cid, size \\ 0) do
    %{cid: cid, size: size, mode: 0o600, classified_by: :declared_extension}
  end
end
