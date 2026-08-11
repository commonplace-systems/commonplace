defmodule Commonplace.Process.SandboxExecTest do
  @moduledoc """
  Tests for sandbox-exec mode in the orchestrator.

  Verifies that __processes.json entries with mode "sandbox-exec"
  spawn a sandbox with a long-running unix process, capture stdout
  to the red event log, and flow file writes back to the CRDT.
  """
  use ExUnit.Case

  alias Commonplace.Process.Orchestrator
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  @orchestrator_interval_ms 100
  @crdt_ready_attempts 50

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_sexec_#{:rand.uniform(1_000_000)}")
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

  describe "sandbox-exec in orchestrator" do
    test "runs a command that writes a file, flows back to CRDT", %{store: store, root: root} do
      # Create __processes.json with a sandbox-exec entry
      create_processes(store, root, %{
        "writer" => %{
          "mode" => "sandbox-exec",
          "command" => "sh",
          "args" => ["-c", "echo 'hello from sandbox' > output.txt"],
          "owns" => "output.txt"
        }
      })

      {:ok, orch} =
        Orchestrator.start_link(
          root_uuid: root,
          store: store,
          interval: @orchestrator_interval_ms
        )

      # CX-6kxv: replace the fixed 800 ms window with readiness polling. The
      # 100 ms step matches the orchestrator interval; 50 steps (5 s) give the
      # nominal launch + write-back pair of intervals 25x scheduling headroom.
      entry = await_crdt_entry(root, store, "output.txt")

      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      content = ContentType.get_content(doc)
      assert String.trim(content) == "hello from sandbox"

      Process.unlink(orch)
      GenServer.stop(orch)
    end

    test "sandbox-exec process can read existing CRDT docs", %{store: store, root: root} do
      # Create an input document
      create_doc(store, root, "input.txt", "42")

      # Run a command that reads and transforms the input
      create_processes(store, root, %{
        "transformer" => %{
          "mode" => "sandbox-exec",
          "command" => "sh",
          "args" => ["-c", "val=$(cat input.txt); echo $(($val * 2)) > doubled.txt"],
          "owns" => "doubled.txt"
        }
      })

      {:ok, orch} =
        Orchestrator.start_link(
          root_uuid: root,
          store: store,
          interval: @orchestrator_interval_ms
        )

      # CX-6kxv: replace the fixed 800 ms window with readiness polling. The
      # 100 ms step matches the orchestrator interval; 50 steps (5 s) give the
      # nominal launch + write-back pair of intervals 25x scheduling headroom.
      entry = await_crdt_entry(root, store, "doubled.txt")

      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert String.trim(ContentType.get_content(doc)) == "84"

      Process.unlink(orch)
      GenServer.stop(orch)
    end
  end

  # Helpers

  defp await_crdt_entry(root, store, filename) do
    Enum.reduce_while(1..@crdt_ready_attempts, :error, fn _, _ ->
      case root |> load_schema(store) |> Schema.get_entry(filename) do
        {:ok, entry} ->
          {:halt, {:ok, entry}}

        :error ->
          Process.sleep(@orchestrator_interval_ms)
          {:cont, :error}
      end
    end)
    |> case do
      {:ok, entry} -> entry
      :error -> flunk("#{filename} not found in CRDT after sandbox-exec")
    end
  end

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
