defmodule Commonplace.GitBridge.ExporterTest do
  use ExUnit.Case, async: true

  alias Commonplace.GitBridge.Exporter
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Presence

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_exporter_store_#{:rand.uniform(1_000_000_000)}")
    repo_dir = Path.join(System.tmp_dir!(), "cp_gb_exporter_repo_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(repo_dir)

    store_name = :"gb_exporter_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(repo_dir)
    end)

    %{store: store_name, repo_dir: repo_dir}
  end

  defp create_text(store, uuid, name, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_map(store, uuid, name, map) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, name)

    doc =
      Enum.reduce(map, doc, fn {k, v}, acc -> ContentType.set_key(acc, k, v) end)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_schema(store, uuid, schema_doc) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  test "exports text and map docs, skips __ / nosync / presence entries", %{store: store, repo_dir: dir} do
    create_text(store, "uuid-a", "a.txt", "hello world")
    create_map(store, "uuid-b", "b.json", %{"k" => "v", "z" => 1})
    create_text(store, "uuid-nosync", "nosync.txt", "should not appear")
    create_text(store, "uuid-sys", "__system", "should not appear")

    {:ok, presence_uuid} = Presence.create("bridge", :bot, "uuid-root", store)

    root =
      Schema.new_schema()
      |> Schema.add_file("a.txt", "uuid-a")
      |> Schema.add_file("b.json", "uuid-b")
      |> Schema.add_file("nosync.txt", "uuid-nosync")
      |> Schema.set_sync("nosync.txt", false)
      |> Schema.add_file("__system", "uuid-sys")

    create_schema(store, "uuid-root", root)

    {:ok, result} = Exporter.export("uuid-root", dir, store)

    assert File.read!(Path.join(dir, "a.txt")) == "hello world"
    assert Jason.decode!(File.read!(Path.join(dir, "b.json"))) == %{"k" => "v", "z" => 1}
    refute File.exists?(Path.join(dir, "nosync.txt"))
    refute File.exists?(Path.join(dir, "__system"))

    presence_fname = Presence.filename("bridge", :bot)
    refute File.exists?(Path.join(dir, presence_fname))
    refute Enum.any?(File.ls!(dir), &(&1 == presence_fname))

    manifest = result.manifest
    assert Map.has_key?(manifest, "a.txt")
    assert Map.has_key?(manifest, "b.json")
    refute Map.has_key?(manifest, "nosync.txt")
    refute Map.has_key?(manifest, "__system")
    refute Map.has_key?(manifest, presence_fname)

    assert manifest["a.txt"].uuid == "uuid-a"
    assert manifest["a.txt"].type == :text
    assert is_binary(manifest["a.txt"].anchor)
    assert MapSet.size(result.authors) == 0
    assert result.warnings == []

    # presence uuid untouched by export
    assert is_binary(presence_uuid)
  end

  test "exports nested directories preserving structure", %{store: store, repo_dir: dir} do
    create_text(store, "uuid-nested", "nested.txt", "deep")

    sub = Schema.new_schema() |> Schema.add_file("nested.txt", "uuid-nested")
    create_schema(store, "uuid-sub", sub)

    root = Schema.new_schema() |> Schema.add_directory("subdir", "uuid-sub")
    create_schema(store, "uuid-root", root)

    {:ok, result} = Exporter.export("uuid-root", dir, store)

    assert File.read!(Path.join(dir, "subdir/nested.txt")) == "deep"
    assert Map.has_key?(result.manifest, "subdir/nested.txt")
  end

  test "collects distinct signer_ids as authors", %{store: store, repo_dir: dir} do
    {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()
    signer_id = Commonplace.Crypto.Signing.signer_id("alice-uuid", pub)

    ctx = %Commonplace.Crypto.SigningContext{
      identity_uuid: "alice-uuid",
      private_key: priv,
      public_key: pub
    }

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "signed.txt")
    doc = ContentType.insert_text(doc, 0, "signed content")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, "uuid-signed", update, nil, %{}, signing_context: ctx)

    root = Schema.new_schema() |> Schema.add_file("signed.txt", "uuid-signed")
    create_schema(store, "uuid-root", root)

    {:ok, result} = Exporter.export("uuid-root", dir, store)

    assert MapSet.member?(result.authors, signer_id)
  end

  test "prunes files removed from previous_manifest but not the new manifest", %{store: store, repo_dir: dir} do
    create_text(store, "uuid-a", "a.txt", "hello")
    root = Schema.new_schema() |> Schema.add_file("a.txt", "uuid-a")
    create_schema(store, "uuid-root", root)

    {:ok, result1} = Exporter.export("uuid-root", dir, store)
    assert File.exists?(Path.join(dir, "a.txt"))

    empty_root = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(empty_root)
    CommitStore.create_chained_commit(store, "uuid-root", update)

    {:ok, result2} = Exporter.export("uuid-root", dir, store, result1.manifest)

    refute File.exists?(Path.join(dir, "a.txt"))
    refute Map.has_key?(result2.manifest, "a.txt")
  end

  test "never prunes .git or .commonplace even if their keys somehow appear in previous_manifest", %{
    store: store,
    repo_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, ".git/HEAD"), "ref: refs/heads/main\n")
    File.mkdir_p!(Path.join(dir, ".commonplace"))
    File.write!(Path.join(dir, ".commonplace/mount.json"), "{}\n")

    empty_root = Schema.new_schema()
    create_schema(store, "uuid-root", empty_root)

    previous = %{
      ".git/HEAD" => %{},
      ".commonplace/mount.json" => %{}
    }

    {:ok, _result} = Exporter.export("uuid-root", dir, store, previous)

    assert File.exists?(Path.join(dir, ".git/HEAD"))
    assert File.exists?(Path.join(dir, ".commonplace/mount.json"))
  end

  test "unrenderable content types are skipped with a warning, not written", %{store: store, repo_dir: dir} do
    # XML doc: renders fine via the tuple-tree JSON rendering (documented
    # deviation), so use a doc with no commits to trigger the true skip path.
    root = Schema.new_schema() |> Schema.add_file("ghost.txt", "uuid-ghost-no-commits")
    create_schema(store, "uuid-root", root)

    {:ok, result} = Exporter.export("uuid-root", dir, store)

    refute File.exists?(Path.join(dir, "ghost.txt"))
    refute Map.has_key?(result.manifest, "ghost.txt")
    assert length(result.warnings) == 1
  end
end
