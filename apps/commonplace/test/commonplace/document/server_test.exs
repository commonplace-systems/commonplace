defmodule Commonplace.Document.ServerTest do
  @moduledoc """
  Tests for Document.Server GenServer behavior:
  apply_update, get_doc, PubSub broadcasting, and init from existing commits.
  """
  use ExUnit.Case

  alias Commonplace.Document.Server
  alias Commonplace.Store.CommitStore
  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    uuid = "doc-server-#{:rand.uniform(1_000_000)}"

    pid =
      start_supervised!(
        {Server, uuid: uuid, commit_store: store_name, client_id: 1},
        id: uuid
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{pid: pid, store: store_name, uuid: uuid, dir: dir}
  end

  describe "get_doc/1" do
    test "returns a Yelixer.Doc struct", %{pid: pid} do
      doc = Server.get_doc(pid)
      assert %Yelixer.Doc{} = doc
    end
  end

  describe "apply_update/2" do
    test "applies a binary update to the document", %{pid: pid} do
      # Create a doc with some content, encode it as an update
      source = Yelixer.Doc.new(client_id: 99)
      source = Commonplace.Document.ContentType.create(source, :text, "Test")
      source = Commonplace.Document.ContentType.insert_text(source, 0, "applied update")
      update = Yelixer.Encoding.encode_update(source)

      assert :ok = Server.apply_update(pid, update)

      assert Server.get_content(pid) == "applied update"
    end

    test "broadcasts on blue channel after apply_update", %{pid: pid, uuid: uuid} do
      CPPubSub.subscribe_blue(uuid)

      source = Yelixer.Doc.new(client_id: 99)
      source = Commonplace.Document.ContentType.create(source, :text, "Test")
      update = Yelixer.Encoding.encode_update(source)

      :ok = Server.apply_update(pid, update)

      assert_receive {"blue:" <> _, ^update}, 1000
    end
  end

  describe "init from existing commits" do
    test "loads state from CommitStore on startup", %{store: store, dir: _dir} do
      uuid = "preloaded-#{:rand.uniform(1_000_000)}"

      # Create a commit in the store first
      doc = Yelixer.Doc.new(client_id: 50)
      doc = Commonplace.Document.ContentType.create(doc, :text, "Preloaded")
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, "existing content")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid, update, nil)

      # Start a server for this UUID — it should load the existing state
      pid =
        start_supervised!(
          {Server, uuid: uuid, commit_store: store, client_id: 2},
          id: uuid
        )

      assert Server.get_content_type(pid) == :text
      assert Server.get_content(pid) == "existing content"
      assert Server.get_meta(pid, "_name") == "Preloaded"
    end

    test "starts with empty doc when no commits exist", %{store: store} do
      uuid = "empty-#{:rand.uniform(1_000_000)}"

      pid =
        start_supervised!(
          {Server, uuid: uuid, commit_store: store, client_id: 3},
          id: uuid
        )

      doc = Server.get_doc(pid)
      assert %Yelixer.Doc{} = doc
      # No content type set yet
      assert Server.get_content_type(pid) == nil
    end
  end

  describe "commit/1" do
    test "chains commits for the same document", %{pid: pid, store: store, uuid: uuid} do
      :ok = Server.create(pid, :text, "Chained")
      :ok = Server.insert_text(pid, 0, "first")
      {:ok, commit1} = Server.commit(pid)

      :ok = Server.insert_text(pid, 5, " second")
      {:ok, commit2} = Server.commit(pid)

      assert commit2.parent_id == commit1.id
      assert commit1.parent_id == nil

      # Latest commit should be commit2
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == commit2.id
    end
  end
end
