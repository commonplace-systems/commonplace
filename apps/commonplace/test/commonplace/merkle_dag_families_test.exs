defmodule Commonplace.MerkleDagFamiliesTest do
  @moduledoc """
  Tests for exotic commit DAG topologies with Yjs documents.

  Every test verifies that the actual document content is sensible
  at every step — not just that commits are stored, but that the
  Yjs state they represent tells a coherent story.
  """
  use ExUnit.Case

  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp new_doc(client_id) do
    doc = Yelixer.Doc.new(client_id: client_id)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  defp text(doc), do: Yelixer.Types.Text.to_string(doc, "text")

  defp insert(doc, index, str), do: Yelixer.Types.Text.insert(doc, "text", index, str)

  defp delete(doc, index, len), do: Yelixer.Types.Text.delete(doc, "text", index, len)

  defp commit(store, uuid, doc, parent_id) do
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, parent_id)
  end

  defp reconstruct(store, commit_id, client_id) do
    {:ok, c} = CommitStore.get_commit(store, commit_id)
    doc = new_doc(client_id)
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, c.update)
    doc
  end

  defp apply_update(doc, update) do
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, update)
    doc
  end

  describe "linear chain — simple notebook editing" do
    test "a series of edits builds a document incrementally", %{store: store} do
      # Alice starts a document
      doc = new_doc(1)
      doc = insert(doc, 0, "# My Notes")
      assert text(doc) == "# My Notes"
      c1 = commit(store, "notebook", doc, nil)

      # She adds a paragraph
      doc = insert(doc, 10, "\n\nFirst thought.")
      assert text(doc) == "# My Notes\n\nFirst thought."
      c2 = commit(store, "notebook", doc, c1.id)

      # She fixes a typo (delete "F", insert "My f")
      doc = delete(doc, 12, 1)
      doc = insert(doc, 12, "My f")
      assert text(doc) == "# My Notes\n\nMy first thought."
      c3 = commit(store, "notebook", doc, c2.id)

      # Verify every historical state is reconstructable
      r1 = reconstruct(store, c1.id, 99)
      assert text(r1) == "# My Notes"

      r2 = reconstruct(store, c2.id, 99)
      assert text(r2) == "# My Notes\n\nFirst thought."

      r3 = reconstruct(store, c3.id, 99)
      assert text(r3) == "# My Notes\n\nMy first thought."
    end
  end

  describe "fork — two branches from a common ancestor" do
    test "branches diverge independently and each is self-consistent", %{store: store} do
      # Common ancestor
      doc = new_doc(1)
      doc = insert(doc, 0, "shared base")
      assert text(doc) == "shared base"
      ancestor = commit(store, "doc", doc, nil)
      ancestor_update = Yelixer.Encoding.encode_update(doc)

      # Branch A: Alice extends
      doc_a = new_doc(2)
      doc_a = apply_update(doc_a, ancestor_update)
      assert text(doc_a) == "shared base"
      doc_a = insert(doc_a, 11, " — alice's version")
      assert text(doc_a) == "shared base — alice's version"
      ca = commit(store, "doc-branch-a", doc_a, ancestor.id)

      # Branch B: Bob takes a different direction
      doc_b = new_doc(3)
      doc_b = apply_update(doc_b, ancestor_update)
      assert text(doc_b) == "shared base"
      doc_b = delete(doc_b, 0, 6)
      doc_b = insert(doc_b, 0, "bob's")
      assert text(doc_b) == "bob's base"
      cb = commit(store, "doc-branch-b", doc_b, ancestor.id)

      # Both branches point to the same ancestor
      {:ok, fa} = CommitStore.get_commit(store, ca.id)
      {:ok, fb} = CommitStore.get_commit(store, cb.id)
      assert fa.parent_id == ancestor.id
      assert fb.parent_id == ancestor.id

      # Reconstructed branches are independent
      ra = reconstruct(store, ca.id, 99)
      rb = reconstruct(store, cb.id, 99)
      assert text(ra) == "shared base — alice's version"
      assert text(rb) == "bob's base"
    end
  end

  describe "diamond merge — two branches rejoin" do
    test "concurrent edits from a fork merge into a single coherent document", %{store: store} do
      # Common ancestor
      base = new_doc(1)
      base = insert(base, 0, "the quick brown fox")
      assert text(base) == "the quick brown fox"
      ancestor = commit(store, "doc", base, nil)
      base_update = Yelixer.Encoding.encode_update(base)

      # Branch A: edits the beginning
      doc_a = new_doc(2)
      doc_a = apply_update(doc_a, base_update)
      doc_a = delete(doc_a, 0, 3)
      doc_a = insert(doc_a, 0, "a")
      assert text(doc_a) == "a quick brown fox"
      ca = commit(store, "doc", doc_a, ancestor.id)

      # Branch B: edits the end
      doc_b = new_doc(3)
      doc_b = apply_update(doc_b, base_update)
      doc_b = insert(doc_b, 19, " jumps over the lazy dog")
      assert text(doc_b) == "the quick brown fox jumps over the lazy dog"
      _cb = commit(store, "doc", doc_b, ancestor.id)

      # Diamond merge: both sides get each other's updates
      update_a = Yelixer.Encoding.encode_update(doc_a)
      update_b = Yelixer.Encoding.encode_update(doc_b)
      merged_a = apply_update(doc_a, update_b)
      merged_b = apply_update(doc_b, update_a)

      # Both sides converge to the same result
      assert text(merged_a) == text(merged_b)

      # The merge has both edits: "a" beginning + "jumps..." ending
      merged_text = text(merged_a)
      assert String.starts_with?(merged_text, "a quick brown fox")
      assert String.ends_with?(merged_text, "jumps over the lazy dog")

      # Commit the merged state
      cm = commit(store, "doc", merged_a, ca.id)

      # DAG shape: ancestor -> ca -> cm, ancestor -> cb (both parents feed cm)
      {:ok, fm} = CommitStore.get_commit(store, cm.id)
      assert fm.parent_id == ca.id

      # Reconstructed merge has both contributions
      rm = reconstruct(store, cm.id, 99)
      assert text(rm) == merged_text
    end
  end

  describe "three-way fork — three branches from one ancestor" do
    test "three independent editors produce three valid branches", %{store: store} do
      # Ancestor
      base = new_doc(1)
      base = insert(base, 0, "TODO: ")
      base_update = Yelixer.Encoding.encode_update(base)
      ancestor = commit(store, "doc", base, nil)

      # Editor 1: adds a task
      d1 = new_doc(10)
      d1 = apply_update(d1, base_update)
      d1 = insert(d1, 6, "buy milk")
      assert text(d1) == "TODO: buy milk"
      c1 = commit(store, "doc", d1, ancestor.id)

      # Editor 2: changes the prefix
      d2 = new_doc(20)
      d2 = apply_update(d2, base_update)
      d2 = delete(d2, 0, 6)
      d2 = insert(d2, 0, "DONE: ")
      assert text(d2) == "DONE: "
      c2 = commit(store, "doc", d2, ancestor.id)

      # Editor 3: adds formatting
      d3 = new_doc(30)
      d3 = apply_update(d3, base_update)
      d3 = insert(d3, 0, "[ ] ")
      assert text(d3) == "[ ] TODO: "
      c3 = commit(store, "doc", d3, ancestor.id)

      # All three share the same parent
      {:ok, f1} = CommitStore.get_commit(store, c1.id)
      {:ok, f2} = CommitStore.get_commit(store, c2.id)
      {:ok, f3} = CommitStore.get_commit(store, c3.id)
      assert f1.parent_id == ancestor.id
      assert f2.parent_id == ancestor.id
      assert f3.parent_id == ancestor.id

      # All three reconstruct independently
      r1 = reconstruct(store, c1.id, 99)
      r2 = reconstruct(store, c2.id, 99)
      r3 = reconstruct(store, c3.id, 99)
      assert text(r1) == "TODO: buy milk"
      assert text(r2) == "DONE: "
      assert text(r3) == "[ ] TODO: "
    end

    test "merging all three branches produces convergent result", %{store: store} do
      base = new_doc(1)
      base = insert(base, 0, "hello")
      base_update = Yelixer.Encoding.encode_update(base)
      _ancestor = commit(store, "doc", base, nil)

      # Three concurrent edits at different positions
      d1 = new_doc(10)
      d1 = apply_update(d1, base_update)
      d1 = insert(d1, 0, "A-")
      assert text(d1) == "A-hello"

      d2 = new_doc(20)
      d2 = apply_update(d2, base_update)
      d2 = insert(d2, 5, "-B")
      assert text(d2) == "hello-B"

      d3 = new_doc(30)
      d3 = apply_update(d3, base_update)
      d3 = insert(d3, 2, "C")
      assert text(d3) == "heCllo"

      # Merge all three into each
      u1 = Yelixer.Encoding.encode_update(d1)
      u2 = Yelixer.Encoding.encode_update(d2)
      u3 = Yelixer.Encoding.encode_update(d3)

      m1 = d1 |> apply_update(u2) |> apply_update(u3)
      m2 = d2 |> apply_update(u1) |> apply_update(u3)
      m3 = d3 |> apply_update(u1) |> apply_update(u2)

      # All three converge
      assert text(m1) == text(m2)
      assert text(m2) == text(m3)

      # All contributions present (C splits "hello" into "he"+"C"+"llo")
      result = text(m1)
      assert String.contains?(result, "A-")
      assert String.contains?(result, "-B")
      assert String.contains?(result, "C")
      assert String.contains?(result, "he")
      assert String.contains?(result, "llo")
    end
  end

  describe "deep chain — many generations" do
    test "10 generations of single-character appends", %{store: store} do
      {doc, parent_id, commits} =
        Enum.reduce(1..10, {new_doc(1), nil, []}, fn i, {doc, parent_id, commits} ->
          doc = insert(doc, i - 1, Integer.to_string(rem(i, 10)))
          c = commit(store, "doc", doc, parent_id)
          {doc, c.id, [c | commits]}
        end)

      # Final document is "1234567890"
      assert text(doc) == "1234567890"

      # Every intermediate state is reconstructable and makes sense
      commits
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.each(fn {c, i} ->
        r = reconstruct(store, c.id, 99)
        expected = Enum.map(1..i, &Integer.to_string(rem(&1, 10))) |> Enum.join()

        assert text(r) == expected,
               "Generation #{i}: expected #{inspect(expected)}, got #{inspect(text(r))}"
      end)

      # Can walk the full chain
      {:ok, last} = CommitStore.latest_commit(store, "doc")
      assert last.id == parent_id

      chain_length =
        Stream.unfold(last.id, fn
          nil ->
            nil

          id ->
            {:ok, c} = CommitStore.get_commit(store, id)
            {c, c.parent_id}
        end)
        |> Enum.count()

      # Post-CX-m3x: the chain includes the deterministic genesis root
      # that auto-stamped on the very first commit, so 10 user commits +
      # 1 genesis = 11.
      assert chain_length == 11
    end
  end

  describe "orphan and graft — late-arriving branch" do
    test "a branch created from an old ancestor still merges correctly", %{store: store} do
      # Build a long mainline
      doc = new_doc(1)
      doc = insert(doc, 0, "version 1")
      c1 = commit(store, "doc", doc, nil)

      doc = delete(doc, 8, 1)
      doc = insert(doc, 8, "2")
      assert text(doc) == "version 2"
      c2 = commit(store, "doc", doc, c1.id)

      doc = delete(doc, 8, 1)
      doc = insert(doc, 8, "3")
      assert text(doc) == "version 3"
      _c3 = commit(store, "doc", doc, c2.id)

      # Late arrival: someone forked from c1 (way back) and made edits
      c1_update = Yelixer.Encoding.encode_update(reconstruct(store, c1.id, 99))
      late = new_doc(50)
      late = apply_update(late, c1_update)
      assert text(late) == "version 1"
      late = insert(late, 9, " (reviewed)")
      assert text(late) == "version 1 (reviewed)"

      # Merge the late branch into current mainline
      late_update = Yelixer.Encoding.encode_update(late)
      merged = apply_update(doc, late_update)

      # The merge should contain both the latest version AND the annotation
      merged_text = text(merged)
      assert String.contains?(merged_text, "3")
      assert String.contains?(merged_text, "(reviewed)")
    end
  end

  describe "mixed types DAG — map and array alongside text" do
    test "commit DAG with multiple CRDT types evolving together", %{store: store} do
      # Create a doc with text, map metadata, and array log
      doc = Yelixer.Doc.new(client_id: 1)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "content", :text)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "meta", :map)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "history", :array)

      # Initial state
      doc = Yelixer.Types.Text.insert(doc, "content", 0, "Hello")
      doc = Yelixer.Types.YMap.set(doc, "meta", "author", "alice")
      doc = Yelixer.Types.YMap.set(doc, "meta", "version", "1")
      doc = Yelixer.Types.Array.push(doc, "history", ["created"])
      c1 = commit(store, "rich-doc", doc, nil)

      assert Yelixer.Types.Text.to_string(doc, "content") == "Hello"
      assert Yelixer.Types.YMap.get(doc, "meta", "author") == "alice"
      assert Yelixer.Types.Array.to_list(doc, "history") == ["created"]

      # Edit
      doc = Yelixer.Types.Text.insert(doc, "content", 5, " World")
      doc = Yelixer.Types.YMap.set(doc, "meta", "version", "2")
      doc = Yelixer.Types.Array.push(doc, "history", ["edited by alice"])
      c2 = commit(store, "rich-doc", doc, c1.id)

      assert Yelixer.Types.Text.to_string(doc, "content") == "Hello World"
      assert Yelixer.Types.YMap.get(doc, "meta", "version") == "2"
      assert Yelixer.Types.Array.to_list(doc, "history") == ["created", "edited by alice"]

      # Reconstruct both commits and verify all types
      r1 = reconstruct_rich(store, c1.id, 99)
      assert Yelixer.Types.Text.to_string(r1, "content") == "Hello"
      assert Yelixer.Types.YMap.get(r1, "meta", "author") == "alice"
      assert Yelixer.Types.Array.to_list(r1, "history") == ["created"]

      r2 = reconstruct_rich(store, c2.id, 99)
      assert Yelixer.Types.Text.to_string(r2, "content") == "Hello World"
      assert Yelixer.Types.YMap.get(r2, "meta", "version") == "2"
      assert Yelixer.Types.Array.to_list(r2, "history") == ["created", "edited by alice"]
    end
  end

  defp reconstruct_rich(store, commit_id, client_id) do
    {:ok, c} = CommitStore.get_commit(store, commit_id)
    doc = Yelixer.Doc.new(client_id: client_id)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "content", :text)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "meta", :map)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "history", :array)
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, c.update)
    doc
  end
end
