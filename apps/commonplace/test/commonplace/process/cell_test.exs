defmodule Commonplace.Process.CellTest do
  @moduledoc """
  Tests for spreadsheet-cell-style reactive processes.

  A Cell subscribes to input documents, and when they change,
  runs a compute function and writes the result to an output doc.
  """
  use ExUnit.Case

  alias Commonplace.Process.Orchestrator
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cell_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    Process.flag(:trap_exit, true)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  describe "cell reactive computation" do
    test "cell computes output from input docs", %{store: store, root: root} do
      # Create input docs
      create_doc(store, root, "price.txt", "42.5")
      create_doc(store, root, "quantity.txt", "10")

      # Create cell source
      create_doc(store, root, "total_cell.exs", """
      defmodule Commonplace.UserProcess.TotalCell do
        use Commonplace.Process.Cell,
          inputs: ["price.txt", "quantity.txt"],
          output: "total.txt"

        def compute(inputs) do
          price = String.to_float(inputs["price.txt"] || "0.0")
          qty = String.to_integer(inputs["quantity.txt"] || "0")
          Float.to_string(price * qty)
        end
      end
      """)

      # Create __processes.json
      create_processes(store, root, %{
        "total_cell" => %{
          "mode" => "elixir",
          "source" => "total_cell.exs",
          "owns" => "total.txt"
        }
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(500)

      # Output doc should have been created with computed value
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "total.txt")
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      content = ContentType.get_content(doc)
      assert content == "425.0"

      Process.unlink(orch)
      GenServer.stop(orch)
    end

    test "cell recomputes when input changes", %{store: store, root: root} do
      create_doc(store, root, "name.txt", "world")

      create_doc(store, root, "greeter_cell.exs", """
      defmodule Commonplace.UserProcess.GreeterCell do
        use Commonplace.Process.Cell,
          inputs: ["name.txt"],
          output: "greeting.txt"

        def compute(inputs) do
          name = inputs["name.txt"] || "stranger"
          "hello, " <> name
        end
      end
      """)

      create_processes(store, root, %{
        "greeter_cell" => %{
          "mode" => "elixir",
          "source" => "greeter_cell.exs",
          "owns" => "greeting.txt"
        }
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(500)

      # Initial computation
      assert read_doc_content(root, "greeting.txt", store) == "hello, world"

      # Update input
      update_doc(store, root, "name.txt", "jes")
      Process.sleep(500)

      # Should recompute
      assert read_doc_content(root, "greeting.txt", store) == "hello, jes"

      Process.unlink(orch)
      GenServer.stop(orch)
    end

    test "cell with no inputs still computes once", %{store: store, root: root} do
      create_doc(store, root, "static_cell.exs", """
      defmodule Commonplace.UserProcess.StaticCell do
        use Commonplace.Process.Cell,
          inputs: [],
          output: "static.txt"

        def compute(_inputs) do
          "I am a static value"
        end
      end
      """)

      create_processes(store, root, %{
        "static_cell" => %{
          "mode" => "elixir",
          "source" => "static_cell.exs",
          "owns" => "static.txt"
        }
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(500)

      assert read_doc_content(root, "static.txt", store) == "I am a static value"

      Process.unlink(orch)
      GenServer.stop(orch)
    end
  end

  # Helpers

  defp create_doc(store, root, filename, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)

    root_doc = load_schema(root, store)
    root_doc = Schema.add_file(root_doc, filename, uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root, update, nil)

    uuid
  end

  defp update_doc(store, root, filename, new_content) do
    root_doc = load_schema(root, store)
    {:ok, entry} = Schema.get_entry(root_doc, filename)

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, new_content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, entry.node_id, update, nil)
  end

  defp read_doc_content(root, filename, store) do
    root_doc = load_schema(root, store)

    case Schema.get_entry(root_doc, filename) do
      {:ok, entry} ->
        {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        ContentType.get_content(doc)

      :error ->
        nil
    end
  end

  defp create_processes(store, root, config) do
    json = Jason.encode!(config)
    root_doc = load_schema(root, store)

    case Schema.get_entry(root_doc, "__processes.json") do
      {:ok, entry} ->
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, json)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, entry.node_id, update, nil)

      :error ->
        uuid = UUID.uuid4()
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, json)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, uuid, update, nil)

        root_doc = load_schema(root, store)
        root_doc = Schema.add_file(root_doc, "__processes.json", uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStore.create_commit(store, root, update, nil)
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
