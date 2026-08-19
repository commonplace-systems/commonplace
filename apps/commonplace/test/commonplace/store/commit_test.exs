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

  describe "new/5 — merge_parents (CX-bv3)" do
    test "merge_parents defaults to empty list" do
      c = Commit.new("doc-a", <<1>>, nil)
      assert c.merge_parents == []
    end

    test "merge_parents is stored on the struct" do
      p1 = Commit.new("doc-a", <<1>>, nil)
      p2 = Commit.new("doc-a", <<2>>, nil)
      c = Commit.new("doc-a", <<9>>, p1.id, %{kind: :merge}, [p2.id])
      assert c.merge_parents == [p2.id]
    end

    test "empty merge_parents preserves the legacy content address" do
      # CX-u7p r2 backward-compat invariant must hold: a commit with
      # no merge_parents and no metadata hashes exactly as before.
      c = Commit.new("doc-a", <<1, 2, 3>>, nil)
      legacy = :crypto.hash(:sha256, <<1, 2, 3>>)
      assert c.id == legacy

      c2 = Commit.new("doc-a", <<4, 5, 6>>, c.id, %{}, [])
      legacy2 = :crypto.hash(:sha256, c.id <> <<4, 5, 6>>)
      assert c2.id == legacy2
    end

    test "non-empty merge_parents changes the content address" do
      p1 = Commit.new("doc-a", <<1>>, nil)
      p2 = Commit.new("doc-a", <<2>>, nil)
      plain = Commit.new("doc-a", <<9>>, p1.id, %{kind: :merge})
      merge = Commit.new("doc-a", <<9>>, p1.id, %{kind: :merge}, [p2.id])

      assert plain.id != merge.id,
             "merge_parents must bind into commit id — otherwise a merge's second parent could be silently forged"
    end

    test "merge_parents order matters" do
      a = :crypto.hash(:sha256, <<"a">>)
      b = :crypto.hash(:sha256, <<"b">>)
      c_ab = Commit.new("doc-a", <<9>>, nil, %{kind: :merge}, [a, b])
      c_ba = Commit.new("doc-a", <<9>>, nil, %{kind: :merge}, [b, a])

      assert c_ab.id != c_ba.id
    end

    test "same merge_parents produce the same id (deterministic)" do
      a = :crypto.hash(:sha256, <<"a">>)
      b = :crypto.hash(:sha256, <<"b">>)
      c1 = Commit.new("doc-a", <<9>>, nil, %{kind: :merge}, [a, b])
      c2 = Commit.new("doc-a", <<9>>, nil, %{kind: :merge}, [a, b])

      assert c1.id == c2.id
    end
  end

  describe "new/5 — :kind enforcement on non-empty metadata (CX-bv3)" do
    test "empty metadata map is still allowed (legacy hatch)" do
      c = Commit.new("doc-a", <<1>>, nil, %{})
      assert c.metadata == %{}
    end

    test "metadata with :kind is accepted" do
      c = Commit.new("doc-a", <<1>>, nil, %{kind: :snapshot})
      assert c.metadata == %{kind: :snapshot}
    end

    test "non-empty metadata without :kind is rejected" do
      assert_raise ArgumentError, ~r/:kind/, fn ->
        Commit.new("doc-a", <<1>>, nil, %{note: "no kind here"})
      end
    end
  end

  describe "genesis/1 — deterministic genesis (CX-fzi)" do
    test "two geneses for the same doc_uuid produce identical hashes" do
      g1 = Commit.genesis("doc-abc")
      g2 = Commit.genesis("doc-abc")

      assert g1.id == g2.id,
             "genesis must be deterministic per doc_uuid — the property that lets re-creations of the same doc converge on the same namespace"
    end

    test "two geneses for different doc_uuids produce different hashes" do
      g_a = Commit.genesis("doc-a")
      g_b = Commit.genesis("doc-b")

      assert g_a.id != g_b.id
    end

    test "genesis has no parent" do
      g = Commit.genesis("doc-a")
      assert g.parent_id == nil
    end

    test "genesis has no merge parents" do
      g = Commit.genesis("doc-a")
      assert g.merge_parents == []
    end

    test "genesis has empty update payload" do
      g = Commit.genesis("doc-a")
      assert g.update == <<>>
    end

    test "genesis metadata is %{kind: :genesis, doc_uuid: <uuid>}" do
      g = Commit.genesis("doc-a")
      assert g.metadata == %{kind: :genesis, doc_uuid: "doc-a"}
    end

    test "genesis records its own doc_uuid on the struct" do
      g = Commit.genesis("doc-a")
      assert g.doc_uuid == "doc-a"
    end

    test "genesis hash matches the spec formula" do
      uuid = "doc-a"

      expected =
        :crypto.hash(
          :sha256,
          <<>> <>
            <<>> <> :erlang.term_to_binary(%{kind: :genesis, doc_uuid: uuid}, [:deterministic])
        )

      assert Commit.genesis(uuid).id == expected
    end

    test "genesis id is distinct from an empty-metadata legacy commit on the same uuid" do
      g = Commit.genesis("doc-a")
      # Legacy empty-metadata commit with no parent and no update would hash
      # sha256(<<>>); genesis hashes sha256(<<>> ∥ <<>> ∥ canonical_metadata(...))
      # — the :kind binding makes them cryptographically distinguishable.
      legacy = Commit.new("doc-a", <<>>, nil)
      assert g.id != legacy.id
    end
  end
end
