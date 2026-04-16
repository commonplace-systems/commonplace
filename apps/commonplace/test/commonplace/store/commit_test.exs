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

    test "empty metadata preserves legacy content-address formula (CX-u7p r2)" do
      # Historical commits were hashed as sha256(parent_id || <<>> <> update).
      # Default metadata %{} must hash the same so existing commits round-trip.
      c = Commit.new("doc-a", <<1, 2, 3>>, nil)
      legacy = :crypto.hash(:sha256, <<1, 2, 3>>)
      assert c.id == legacy

      c2 = Commit.new("doc-a", <<4, 5, 6>>, c.id)
      legacy2 = :crypto.hash(:sha256, c.id <> <<4, 5, 6>>)
      assert c2.id == legacy2
    end

    test "non-empty metadata changes the content address (CX-u7p r2)" do
      c_plain = Commit.new("doc-a", <<1, 2, 3>>, nil)
      c_snap = Commit.new("doc-a", <<1, 2, 3>>, nil, %{kind: :snapshot})

      assert c_plain.id != c_snap.id,
             "snapshot metadata must bind into commit id — otherwise a peer could retag a commit as a snapshot without changing its id"
    end

    test "metadata is deterministic: same map hashes the same" do
      c1 = Commit.new("doc-a", <<1>>, nil, %{kind: :snapshot, note: "n"})
      c2 = Commit.new("doc-a", <<1>>, nil, %{note: "n", kind: :snapshot})

      assert c1.id == c2.id
    end

    test "different metadata values produce different ids" do
      c1 = Commit.new("doc-a", <<1>>, nil, %{kind: :snapshot})
      c2 = Commit.new("doc-a", <<1>>, nil, %{kind: :checkpoint})

      assert c1.id != c2.id
    end
  end
end
