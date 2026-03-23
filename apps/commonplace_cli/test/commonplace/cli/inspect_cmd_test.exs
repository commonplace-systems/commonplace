defmodule Commonplace.CLI.InspectCmdTest do
  @moduledoc """
  Tests for the `commonplace inspect` CLI command.
  """
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_inspect_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_inspect_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  describe "inspect output" do
    test "shows document structure for a text document", %{store: store} do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "Hello, World!")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)

      output =
        capture_io(fn ->
          Commonplace.CLI.InspectCmd.run_with_store(nil, store, uuid)
        end)

      assert output =~ "Document: #{uuid}"
      assert output =~ "Commit:"
      assert output =~ "Types:"
      assert output =~ "Content type: text"
      assert output =~ "Content preview: Hello, World!"
      assert output =~ "State vector"
      assert output =~ "client"
      assert output =~ "Blocks:"
      assert output =~ "Items:"
      assert output =~ "Delete set:"
    end

    test "shows block and item counts", %{store: store} do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "counts.txt")
      doc = ContentType.insert_text(doc, 0, "abc")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)

      output =
        capture_io(fn ->
          Commonplace.CLI.InspectCmd.run_with_store(nil, store, uuid)
        end)

      assert output =~ ~r/Blocks: \d+/
      assert output =~ ~r/Items: \d+/
    end

    test "shows map document content preview", %{store: store} do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :map, "data.json")
      doc = ContentType.set_key(doc, "name", "test")
      doc = ContentType.set_key(doc, "count", 42)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)

      output =
        capture_io(fn ->
          Commonplace.CLI.InspectCmd.run_with_store(nil, store, uuid)
        end)

      assert output =~ "Content type: map"
      assert output =~ "Content preview:"
      assert output =~ "name"
      assert output =~ "count"
    end

    test "truncates long text content preview", %{store: store} do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "long.txt")
      long_text = String.duplicate("x", 200)
      doc = ContentType.insert_text(doc, 0, long_text)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)

      output =
        capture_io(fn ->
          Commonplace.CLI.InspectCmd.run_with_store(nil, store, uuid)
        end)

      assert output =~ "..."
    end

    test "reports error for missing document", %{store: store} do
      uuid = UUID.uuid4()

      output =
        capture_io(:stderr, fn ->
          Commonplace.CLI.InspectCmd.run_with_store(nil, store, uuid)
        end)

      assert output =~ "No commits found for: #{uuid}"
    end

    test "shows state vector with correct client count", %{store: store} do
      uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "sv.txt")
      doc = ContentType.insert_text(doc, 0, "test")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)

      output =
        capture_io(fn ->
          Commonplace.CLI.InspectCmd.run_with_store(nil, store, uuid)
        end)

      assert output =~ "State vector (1 client(s)):"
      assert output =~ ~r/client \d+: clock \d+/
    end
  end
end
