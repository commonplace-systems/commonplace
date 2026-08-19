defmodule Commonplace.CLI.RoundtripTest do
  @moduledoc """
  Integration test: import a directory → export it → compare contents.
  The roundtrip should preserve file content exactly.
  """
  use ExUnit.Case

  alias Commonplace.CLI
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Sync.Export

  setup do
    workspace = Path.join(System.tmp_dir!(), "cp_rt_ws_#{:rand.uniform(1_000_000)}")
    source = Path.join(System.tmp_dir!(), "cp_rt_src_#{:rand.uniform(1_000_000)}")
    output = Path.join(System.tmp_dir!(), "cp_rt_out_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(workspace)
    File.mkdir_p!(source)
    File.mkdir_p!(output)

    on_exit(fn ->
      _ = Application.stop(:commonplace)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data", persistent: true)
      File.rm_rf!(workspace)
      File.rm_rf!(source)
      File.rm_rf!(output)
      {:ok, _} = Application.ensure_all_started(:commonplace)
    end)

    %{workspace: workspace, source: source, output: output}
  end

  test "import → export roundtrip preserves all files", %{
    workspace: ws,
    source: src,
    output: out
  } do
    # Create source tree
    File.write!(Path.join(src, "readme.txt"), "# Hello\n\nThis is a test.\n")
    File.write!(Path.join(src, "empty.txt"), "")
    File.mkdir_p!(Path.join(src, "docs"))
    File.write!(Path.join(src, "docs/guide.txt"), "Step 1: do the thing\nStep 2: done\n")
    File.mkdir_p!(Path.join(src, "docs/examples"))
    File.write!(Path.join(src, "docs/examples/hello.txt"), "hello world\n")
    File.mkdir_p!(Path.join(src, "empty_dir"))

    # Init workspace
    CLI.ensure_started(ws)
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(root_uuid, update, nil)
    CLI.set_root_uuid(ws, root_uuid)

    # Import
    root_doc = load_schema(root_uuid)
    root_doc = import_directory(src, root_doc)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(root_uuid, update, nil)

    # Export
    Export.export(root_uuid, out)

    # Compare
    assert File.read!(Path.join(out, "readme.txt")) == "# Hello\n\nThis is a test.\n"
    assert File.read!(Path.join(out, "empty.txt")) == ""

    assert File.read!(Path.join(out, "docs/guide.txt")) ==
             "Step 1: do the thing\nStep 2: done\n"

    assert File.read!(Path.join(out, "docs/examples/hello.txt")) == "hello world\n"
    assert File.dir?(Path.join(out, "empty_dir"))
    assert File.ls!(Path.join(out, "empty_dir")) == []
  end

  test "roundtrip preserves special characters in content", %{
    workspace: ws,
    source: src,
    output: out
  } do
    content = "tabs:\t\there\nnewlines\n\n\nquotes: \"hello\" 'world'\nunicode: 日本語 🎉\n"
    File.write!(Path.join(src, "special.txt"), content)

    CLI.ensure_started(ws)
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(root_uuid, update, nil)
    CLI.set_root_uuid(ws, root_uuid)

    root_doc = load_schema(root_uuid)
    root_doc = import_directory(src, root_doc)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(root_uuid, update, nil)

    Export.export(root_uuid, out)

    assert File.read!(Path.join(out, "special.txt")) == content
  end

  # --- Helpers (same as CLI import logic) ---

  defp load_schema(uuid) do
    case CommitStore.latest_commit(uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp import_directory(dir_path, schema_doc) do
    File.ls!(dir_path)
    |> Enum.sort()
    |> Enum.reduce(schema_doc, fn name, schema ->
      full_path = Path.join(dir_path, name)

      cond do
        File.dir?(full_path) ->
          sub_uuid = UUID.uuid4()
          sub_schema = Schema.new_schema()
          sub_schema = import_directory(full_path, sub_schema)
          update = Yelixer.Encoding.encode_update(sub_schema)
          CommitStore.create_commit(sub_uuid, update, nil)
          Schema.add_directory(schema, name, sub_uuid)

        File.regular?(full_path) ->
          file_uuid = UUID.uuid4()
          content = File.read!(full_path)
          doc = Yelixer.Doc.new()
          doc = ContentType.create(doc, :text, name)

          doc =
            if content != "" do
              ContentType.insert_text(doc, 0, content)
            else
              doc
            end

          update = Yelixer.Encoding.encode_update(doc)
          CommitStore.create_commit(file_uuid, update, nil)
          Schema.add_file(schema, name, file_uuid)

        true ->
          schema
      end
    end)
  end
end
