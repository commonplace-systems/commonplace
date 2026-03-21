defmodule Commonplace.Store.CommitTest do
  use ExUnit.Case, async: true

  alias Commonplace.Store.Commit

  describe "new/3" do
    test "creates a commit with content-addressed ID" do
      commit = Commit.new("doc-uuid-1", <<1, 2, 3>>, nil)

      assert commit.doc_uuid == "doc-uuid-1"
      assert commit.update == <<1, 2, 3>>
      assert commit.parent_id == nil
      assert is_binary(commit.id)
      assert byte_size(commit.id) == 32
    end

    test "same update and parent produce the same ID" do
      c1 = Commit.new("doc-a", <<1, 2, 3>>, nil)
      c2 = Commit.new("doc-b", <<1, 2, 3>>, nil)

      assert c1.id == c2.id
    end

    test "different updates produce different IDs" do
      c1 = Commit.new("doc-a", <<1, 2, 3>>, nil)
      c2 = Commit.new("doc-a", <<4, 5, 6>>, nil)

      assert c1.id != c2.id
    end

    test "parent ID changes the content address" do
      parent = Commit.new("doc-a", <<1, 2, 3>>, nil)
      c1 = Commit.new("doc-a", <<4, 5, 6>>, nil)
      c2 = Commit.new("doc-a", <<4, 5, 6>>, parent.id)

      assert c1.id != c2.id
    end

    test "forms a chain where each commit references its parent" do
      c1 = Commit.new("doc-a", <<1>>, nil)
      c2 = Commit.new("doc-a", <<2>>, c1.id)
      c3 = Commit.new("doc-a", <<3>>, c2.id)

      assert c1.parent_id == nil
      assert c2.parent_id == c1.id
      assert c3.parent_id == c2.id
    end

    test "includes a timestamp" do
      before = DateTime.utc_now()
      commit = Commit.new("doc-a", <<1>>, nil)
      after_ts = DateTime.utc_now()

      assert DateTime.compare(commit.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(commit.timestamp, after_ts) in [:lt, :eq]
    end
  end
end
