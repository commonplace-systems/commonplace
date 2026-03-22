defmodule Commonplace.Process.SandboxTest do
  @moduledoc """
  Tests for sync sandbox — filesystem isolation for unix processes.

  Each sandbox-exec process gets a temp directory with a SyncLoop
  materializing its CRDT subtree. The process runs in the sandbox
  and writes flow back to the CRDT.
  """
  use ExUnit.Case

  alias Commonplace.Process.Sandbox
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_sandbox_#{:rand.uniform(1_000_000)}")
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

  describe "sandbox lifecycle" do
    test "creates sandbox dir and materializes CRDT subtree", %{store: store, root: root} do
      # Create a document in the CRDT
      create_doc(store, root, "input.txt", "hello sandbox")

      {:ok, sandbox} = Sandbox.start_link(
        root_uuid: root,
        store: store,
        sync_interval: 50
      )

      Process.sleep(300)

      # Sandbox dir should exist with the file
      sandbox_dir = Sandbox.dir(sandbox)
      assert File.dir?(sandbox_dir)
      assert File.read!(Path.join(sandbox_dir, "input.txt")) == "hello sandbox"

      Sandbox.stop(sandbox)
    end

    test "writes in sandbox flow back to CRDT", %{store: store, root: root} do
      {:ok, sandbox} = Sandbox.start_link(
        root_uuid: root,
        store: store,
        sync_interval: 50
      )

      Process.sleep(200)

      # Write a file in the sandbox
      sandbox_dir = Sandbox.dir(sandbox)
      File.write!(Path.join(sandbox_dir, "output.txt"), "from process")

      Process.sleep(300)

      # Should appear in CRDT
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "output.txt")
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert ContentType.get_content(doc) == "from process"

      Sandbox.stop(sandbox)
    end

    test "cleanup removes sandbox dir on stop", %{store: store, root: root} do
      {:ok, sandbox} = Sandbox.start_link(
        root_uuid: root,
        store: store,
        sync_interval: 50
      )

      sandbox_dir = Sandbox.dir(sandbox)
      assert File.dir?(sandbox_dir)

      Sandbox.stop(sandbox)
      Process.sleep(100)

      refute File.dir?(sandbox_dir)
    end
  end

  describe "running commands in sandbox" do
    test "runs a command and captures stdout", %{store: store, root: root} do
      {:ok, sandbox} = Sandbox.start_link(
        root_uuid: root,
        store: store,
        sync_interval: 50
      )

      Process.sleep(200)

      # Run a simple command
      {output, 0} = Sandbox.exec(sandbox, "echo", ["hello from sandbox"])
      assert String.trim(output) == "hello from sandbox"

      Sandbox.stop(sandbox)
    end

    test "command runs in sandbox directory", %{store: store, root: root} do
      create_doc(store, root, "data.txt", "42")

      {:ok, sandbox} = Sandbox.start_link(
        root_uuid: root,
        store: store,
        sync_interval: 50
      )

      Process.sleep(300)

      # Command should see files in sandbox
      {output, 0} = Sandbox.exec(sandbox, "cat", ["data.txt"])
      assert String.trim(output) == "42"

      Sandbox.stop(sandbox)
    end

    test "command output written to file flows back to CRDT", %{store: store, root: root} do
      {:ok, sandbox} = Sandbox.start_link(
        root_uuid: root,
        store: store,
        sync_interval: 50
      )

      Process.sleep(200)

      # Run a command that writes a file
      _sandbox_dir = Sandbox.dir(sandbox)
      {_output, 0} = Sandbox.exec(sandbox, "sh", ["-c", "echo computed > result.txt"])

      Process.sleep(400)

      # Should flow back to CRDT
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "result.txt")
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert String.trim(ContentType.get_content(doc)) == "computed"

      Sandbox.stop(sandbox)
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
