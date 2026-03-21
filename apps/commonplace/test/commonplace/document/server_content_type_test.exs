defmodule Commonplace.Document.ServerContentTypeTest do
  use ExUnit.Case

  alias Commonplace.Document.Server
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    uuid = "doc-#{:rand.uniform(1_000_000)}"

    pid =
      start_supervised!(
        {Server, uuid: uuid, commit_store: store_name, client_id: 1},
        id: uuid
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{pid: pid, store: store_name, uuid: uuid}
  end

  describe "create/3" do
    test "initializes a text document via server", %{pid: pid} do
      assert :ok = Server.create(pid, :text, "My Notes")
      assert Server.get_content_type(pid) == :text
      assert Server.get_meta(pid, "_name") == "My Notes"
    end

    test "initializes a map document via server", %{pid: pid} do
      assert :ok = Server.create(pid, :map, "Config")
      assert Server.get_content_type(pid) == :map
    end

    test "initializes an array document via server", %{pid: pid} do
      assert :ok = Server.create(pid, :array, "Log")
      assert Server.get_content_type(pid) == :array
    end
  end

  describe "insert_text/3" do
    test "inserts text into a text document", %{pid: pid} do
      :ok = Server.create(pid, :text, "Notes")
      :ok = Server.insert_text(pid, 0, "hello world")

      assert Server.get_content(pid) == "hello world"
    end

    test "inserts at various positions", %{pid: pid} do
      :ok = Server.create(pid, :text, "Notes")
      :ok = Server.insert_text(pid, 0, "hello")
      :ok = Server.insert_text(pid, 5, " world")
      :ok = Server.insert_text(pid, 5, " beautiful")

      assert Server.get_content(pid) == "hello beautiful world"
    end
  end

  describe "set_key/3" do
    test "sets keys in a map document", %{pid: pid} do
      :ok = Server.create(pid, :map, "Config")
      :ok = Server.set_key(pid, "theme", "dark")
      :ok = Server.set_key(pid, "font_size", 14)

      content = Server.get_content(pid)
      assert content["theme"] == "dark"
      assert content["font_size"] == 14
    end
  end

  describe "get_content/1" do
    test "returns empty content for freshly created text doc", %{pid: pid} do
      :ok = Server.create(pid, :text, "Notes")
      assert Server.get_content(pid) == ""
    end

    test "returns empty content for freshly created map doc", %{pid: pid} do
      :ok = Server.create(pid, :map, "Config")
      assert Server.get_content(pid) == %{}
    end

    test "returns empty content for freshly created array doc", %{pid: pid} do
      :ok = Server.create(pid, :array, "Log")
      assert Server.get_content(pid) == []
    end
  end

  describe "get_meta/2" do
    test "reads metadata from the envelope", %{pid: pid} do
      :ok = Server.create(pid, :text, "Notes")
      assert Server.get_meta(pid, "_type") == "text"
      assert Server.get_meta(pid, "_name") == "Notes"
    end
  end

  describe "commit roundtrip with content type" do
    test "text document survives commit and reload", %{store: store, uuid: uuid} do
      pid =
        start_supervised!(
          {Server, uuid: uuid <> "-rt", commit_store: store, client_id: 1},
          id: uuid <> "-rt"
        )

      :ok = Server.create(pid, :text, "Notes")
      :ok = Server.insert_text(pid, 0, "persisted text")
      {:ok, _commit} = Server.commit(pid)

      # Stop and restart with a new client_id
      stop_supervised!(uuid <> "-rt")

      new_pid =
        start_supervised!(
          {Server, uuid: uuid <> "-rt", commit_store: store, client_id: 2},
          id: uuid <> "-rt-2"
        )

      assert Server.get_content_type(new_pid) == :text
      assert Server.get_meta(new_pid, "_name") == "Notes"
      assert Server.get_content(new_pid) == "persisted text"
    end
  end
end
