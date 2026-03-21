defmodule Commonplace.Document.ContentTypeTest do
  use ExUnit.Case

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  describe "create/3 — text documents" do
    test "creates a text document with envelope structure" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "My Notes")

      assert ContentType.get_type(doc) == :text
      assert ContentType.get_meta(doc, "_name") == "My Notes"
      assert ContentType.get_meta(doc, "_type") == "text"
    end

    test "text content is initially empty" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Empty")

      assert ContentType.get_content(doc) == ""
    end

    test "can insert text into content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Notes")
      doc = ContentType.insert_text(doc, 0, "hello world")

      assert ContentType.get_content(doc) == "hello world"
    end

    test "can delete text from content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Notes")
      doc = ContentType.insert_text(doc, 0, "hello world")
      doc = ContentType.delete_text(doc, 0, 6)

      assert ContentType.get_content(doc) == "world"
    end
  end

  describe "create/3 — map documents" do
    test "creates a map document with envelope structure" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :map, "Config")

      assert ContentType.get_type(doc) == :map
      assert ContentType.get_meta(doc, "_name") == "Config"
    end

    test "map content is initially empty" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :map, "Config")

      assert ContentType.get_content(doc) == %{}
    end

    test "can set and get keys in map content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :map, "Config")
      doc = ContentType.set_key(doc, "theme", "dark")
      doc = ContentType.set_key(doc, "font_size", 14)

      content = ContentType.get_content(doc)
      assert content == %{"theme" => "dark", "font_size" => 14}
    end

    test "can delete keys in map content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :map, "Config")
      doc = ContentType.set_key(doc, "a", 1)
      doc = ContentType.set_key(doc, "b", 2)
      doc = ContentType.delete_key(doc, "a")

      content = ContentType.get_content(doc)
      assert content == %{"b" => 2}
    end
  end

  describe "create/3 — array documents" do
    test "creates an array document with envelope structure" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :array, "Event Log")

      assert ContentType.get_type(doc) == :array
      assert ContentType.get_meta(doc, "_name") == "Event Log"
    end

    test "array content is initially empty" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :array, "Log")

      assert ContentType.get_content(doc) == []
    end

    test "can push elements to array content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :array, "Log")
      doc = ContentType.push_items(doc, ["event-1"])
      doc = ContentType.push_items(doc, ["event-2", "event-3"])

      assert ContentType.get_content(doc) == ["event-1", "event-2", "event-3"]
    end

    test "can insert elements at index in array content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :array, "Log")
      doc = ContentType.push_items(doc, ["a", "c"])
      doc = ContentType.insert_items(doc, 1, ["b"])

      assert ContentType.get_content(doc) == ["a", "b", "c"]
    end

    test "can delete elements from array content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :array, "Log")
      doc = ContentType.push_items(doc, ["a", "b", "c"])
      doc = ContentType.delete_items(doc, 1, 1)

      assert ContentType.get_content(doc) == ["a", "c"]
    end
  end

  describe "create/3 — xml stub" do
    test "xml type returns :xml but is not implemented for content" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :xml, "Page")

      assert ContentType.get_type(doc) == :xml
      assert ContentType.get_meta(doc, "_name") == "Page"
      assert ContentType.get_content(doc) == nil
    end
  end

  describe "metadata" do
    test "can set and get arbitrary metadata" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Notes")
      doc = ContentType.set_meta(doc, "author", "alice")
      doc = ContentType.set_meta(doc, "tags", "draft")

      assert ContentType.get_meta(doc, "author") == "alice"
      assert ContentType.get_meta(doc, "tags") == "draft"
    end

    test "metadata does not conflict with _type and _name" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Notes")
      doc = ContentType.set_meta(doc, "author", "alice")

      assert ContentType.get_meta(doc, "_type") == "text"
      assert ContentType.get_meta(doc, "_name") == "Notes"
      assert ContentType.get_meta(doc, "author") == "alice"
    end

    test "can overwrite metadata" do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Notes")
      doc = ContentType.set_meta(doc, "status", "draft")
      doc = ContentType.set_meta(doc, "status", "published")

      assert ContentType.get_meta(doc, "status") == "published"
    end
  end

  describe "commit/reconstruct roundtrip" do
    setup do
      dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      name = :"commit_store_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: name})
      on_exit(fn -> File.rm_rf!(dir) end)
      %{store: name}
    end

    test "text document survives commit/replay", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Notes")
      doc = ContentType.insert_text(doc, 0, "persisted text")

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "doc-1", update, nil)

      {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      new_doc = Yelixer.Doc.new(client_id: 2)
      {:ok, new_doc} = Yelixer.Encoding.apply_update(new_doc, fetched.update)

      # After roundtrip, we need to re-register the types so ContentType can read them
      assert ContentType.get_type(new_doc) == :text
      assert ContentType.get_meta(new_doc, "_name") == "Notes"
      assert ContentType.get_content(new_doc) == "persisted text"
    end

    test "map document survives commit/replay", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :map, "Config")
      doc = ContentType.set_key(doc, "theme", "dark")
      doc = ContentType.set_key(doc, "font_size", 14)

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "doc-2", update, nil)

      {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      new_doc = Yelixer.Doc.new(client_id: 2)
      {:ok, new_doc} = Yelixer.Encoding.apply_update(new_doc, fetched.update)

      assert ContentType.get_type(new_doc) == :map
      assert ContentType.get_meta(new_doc, "_name") == "Config"
      assert ContentType.get_content(new_doc) == %{"theme" => "dark", "font_size" => 14}
    end

    test "array document survives commit/replay", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :array, "Log")
      doc = ContentType.push_items(doc, ["event-1", "event-2"])

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "doc-3", update, nil)

      {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      new_doc = Yelixer.Doc.new(client_id: 2)
      {:ok, new_doc} = Yelixer.Encoding.apply_update(new_doc, fetched.update)

      assert ContentType.get_type(new_doc) == :array
      assert ContentType.get_meta(new_doc, "_name") == "Log"
      assert ContentType.get_content(new_doc) == ["event-1", "event-2"]
    end

    test "metadata survives commit/replay", %{store: store} do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "Notes")
      doc = ContentType.set_meta(doc, "author", "alice")
      doc = ContentType.set_meta(doc, "version", "2")

      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, "doc-4", update, nil)

      {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      new_doc = Yelixer.Doc.new(client_id: 2)
      {:ok, new_doc} = Yelixer.Encoding.apply_update(new_doc, fetched.update)

      assert ContentType.get_meta(new_doc, "author") == "alice"
      assert ContentType.get_meta(new_doc, "version") == "2"
    end
  end

  describe "multiple documents coexist" do
    test "different types can be created independently" do
      text_doc = Yelixer.Doc.new(client_id: 1)
      text_doc = ContentType.create(text_doc, :text, "My Notes")
      text_doc = ContentType.insert_text(text_doc, 0, "hello")

      map_doc = Yelixer.Doc.new(client_id: 2)
      map_doc = ContentType.create(map_doc, :map, "Config")
      map_doc = ContentType.set_key(map_doc, "key", "value")

      array_doc = Yelixer.Doc.new(client_id: 3)
      array_doc = ContentType.create(array_doc, :array, "Log")
      array_doc = ContentType.push_items(array_doc, ["event"])

      assert ContentType.get_type(text_doc) == :text
      assert ContentType.get_content(text_doc) == "hello"

      assert ContentType.get_type(map_doc) == :map
      assert ContentType.get_content(map_doc) == %{"key" => "value"}

      assert ContentType.get_type(array_doc) == :array
      assert ContentType.get_content(array_doc) == ["event"]
    end
  end
end
