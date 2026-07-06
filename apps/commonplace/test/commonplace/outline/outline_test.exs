defmodule Commonplace.OutlineTest do
  @moduledoc """
  CX-saix(ii): the Outline mutation layer on the flat bag of XML items
  (outliner.md §2-§4), verifying the ONE load-bearing integration
  assumption first — structured XML ops committed through the normal
  CRDT-update path (chat's commit_entry idiom) — plus the snapshot
  regression pin (xml replays structurally; the R5 guard must NOT
  refuse an outline doc).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Outline
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_outline_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store = :"outline_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    root_uuid = UUID.uuid4()
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store, root: root_uuid}
  end

  defp texts(items), do: Map.new(items, &{&1.id, &1.text})

  test "commit entrypoint: structured ops → chained commits → faithful reconstruction",
       %{store: store, root: root} do
    {:ok, uuid} = Outline.create("groceries", root, store)

    {:ok, a} = Outline.add_item(store, uuid, %{text: "Groceries"})
    {:ok, b} = Outline.add_item(store, uuid, %{text: "Milk", parent: a})
    {:ok, c} = Outline.add_item(store, uuid, %{text: "Eggs", parent: a, after: b})

    items = Outline.items(store, uuid)
    assert length(items) == 3

    by_id = Map.new(items, &{&1.id, &1})
    assert by_id[a].parent == ""
    assert by_id[b].parent == a
    assert by_id[c].parent == a
    # b before c among a's children, by (order, id).
    assert by_id[b].order < by_id[c].order or
             (by_id[b].order == by_id[c].order and b < c)

    assert texts(items) == %{a => "Groceries", b => "Milk", c => "Eggs"}

    # Edit text and confirm it round-trips through a fresh reconstruction.
    :ok = Outline.set_text(store, uuid, b, "Milk (2%)")
    assert %{^b => "Milk (2%)"} = texts(Outline.items(store, uuid))
  end

  test "snapshot pin: an outline doc survives compaction byte-faithfully (R5 must not refuse)",
       %{store: store, root: root} do
    {:ok, uuid} = Outline.create("snap", root, store)
    {:ok, a} = Outline.add_item(store, uuid, %{text: "Top"})
    {:ok, b} = Outline.add_item(store, uuid, %{text: "Child", parent: a})
    :ok = Outline.set_collapsed(store, uuid, a, true)

    before = Outline.items(store, uuid) |> Enum.sort_by(& &1.id)

    # The R5 guard refuses docs whose nested sub-types can't replay —
    # xml MUST pass (doc.ex replay_xml_*; pre-noodle msgs 5150/5152).
    assert {:ok, _snapshot} = CommitStore.snapshot(store, uuid)

    # Continue mutating ON TOP of the snapshot, then reconstruct.
    {:ok, _c} = Outline.add_item(store, uuid, %{text: "Post-snapshot", parent: b})
    after_items = Outline.items(store, uuid)

    assert length(after_items) == 3
    surviving = after_items |> Enum.filter(&(&1.id in [a, b])) |> Enum.sort_by(& &1.id)

    assert Enum.map(surviving, &{&1.id, &1.parent, &1.order, &1.collapsed, &1.text}) ==
             Enum.map(before, &{&1.id, &1.parent, &1.order, &1.collapsed, &1.text})
  end

  test "indent/outdent are pure attribute edits — the element is never destroyed",
       %{store: store, root: root} do
    {:ok, uuid} = Outline.create("move", root, store)
    {:ok, a} = Outline.add_item(store, uuid, %{text: "First"})
    {:ok, b} = Outline.add_item(store, uuid, %{text: "Second", after: a})

    # Indent b: parent becomes its preceding sibling a.
    :ok = Outline.indent(store, uuid, b)
    by_id = Map.new(Outline.items(store, uuid), &{&1.id, &1})
    assert by_id[b].parent == a
    assert by_id[b].text == "Second"

    # Outdent b: back to top level, ordered after a.
    :ok = Outline.outdent(store, uuid, b)
    by_id = Map.new(Outline.items(store, uuid), &{&1.id, &1})
    assert by_id[b].parent == ""
    assert by_id[a].order < by_id[b].order

    # First item can't indent.
    assert {:error, :no_preceding_sibling} = Outline.indent(store, uuid, a)
  end

  test "reorder moves an item among its siblings", %{store: store, root: root} do
    {:ok, uuid} = Outline.create("reorder", root, store)
    {:ok, a} = Outline.add_item(store, uuid, %{text: "1"})
    {:ok, b} = Outline.add_item(store, uuid, %{text: "2", after: a})
    {:ok, c} = Outline.add_item(store, uuid, %{text: "3", after: b})

    :ok = Outline.reorder(store, uuid, c, :up)

    order = Outline.items(store, uuid) |> Enum.sort_by(&{&1.order, &1.id}) |> Enum.map(& &1.id)
    assert order == [a, c, b]

    :ok = Outline.reorder(store, uuid, a, :down)
    order = Outline.items(store, uuid) |> Enum.sort_by(&{&1.order, &1.id}) |> Enum.map(& &1.id)
    assert order == [c, a, b]
  end

  test "delete_item removes the item from the bag", %{store: store, root: root} do
    {:ok, uuid} = Outline.create("del", root, store)
    {:ok, a} = Outline.add_item(store, uuid, %{text: "Keep"})
    {:ok, b} = Outline.add_item(store, uuid, %{text: "Drop", after: a})

    :ok = Outline.delete_item(store, uuid, b)
    assert [%{id: ^a}] = Outline.items(store, uuid)
  end

  test "concurrent reparent is LWW with no duplication, and text edits survive the move" do
    # Pure CRDT-semantics check (no store): two replicas diverge from a
    # shared base — one reparents X under P1, the other reparents X
    # under P2 AND edits X's text. Cross-apply: exactly one parent wins,
    # the element is unique, and the text edit survives.
    {doc, x} = base_outline_doc()

    {:ok, base} = ok(Yelixer.Encoding.encode_update(doc))

    replica_a = apply!(Yelixer.Doc.new(client_id: 111), base)
    replica_b = apply!(Yelixer.Doc.new(client_id: 222), base)

    replica_a = set_item_attr(replica_a, x, "parent", "p1")
    replica_b = set_item_attr(replica_b, x, "parent", "p2")
    replica_b = append_item_text(replica_b, x, " (urgent)")

    update_a = Yelixer.Encoding.encode_update(replica_a)
    update_b = Yelixer.Encoding.encode_update(replica_b)

    merged_a = apply!(replica_a, update_b)
    merged_b = apply!(replica_b, update_a)

    for merged <- [merged_a, merged_b] do
      items = materialize(merged)
      xs = Enum.filter(items, &(&1.id == x))
      assert length(xs) == 1, "the moved element must not duplicate"
      assert hd(xs).parent in ["p1", "p2"]
      assert hd(xs).text =~ "(urgent)"
    end

    # Both replicas converge on the SAME winner.
    assert materialize(merged_a) |> Enum.find(&(&1.id == x)) |> Map.get(:parent) ==
             materialize(merged_b) |> Enum.find(&(&1.id == x)) |> Map.get(:parent)
  end

  # --- helpers for the pure-CRDT test ---

  defp ok(v), do: {:ok, v}
  defp apply!(doc, update), do: ({:ok, d} = Yelixer.Encoding.apply_update(doc, update); d)

  defp base_outline_doc do
    doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(client_id: 1), :xml, "_outline")
    doc = Outline.Internal.insert_item(doc, "x1", "", "V", "Task X")
    {doc, "x1"}
  end

  defp set_item_attr(doc, id, key, value) do
    Outline.Internal.set_item_attribute(doc, id, key, value)
  end

  defp append_item_text(doc, id, suffix) do
    Outline.Internal.append_item_text(doc, id, suffix)
  end

  defp materialize(doc), do: Outline.Internal.materialize_items(doc)

  describe "writer identity — stable per-doc hand (CX-41qg.3)" do
    # `Outline.mutate/4` reconstructs the FULL commit chain via
    # `DocBuilder.reconstruct_doc/3` before re-encoding each mutation.
    # Before this fix that call passed no client_id, so every add/edit/
    # move/delete minted a fresh random one — this pins the fix the
    # same way `command_router_test.exs`'s "writer identity" describe
    # block pins CommandRouter's.
    defp sv_client_ids(doc) do
      Yelixer.BlockStore.state_vector(doc.store).clocks
      |> Map.keys()
      |> MapSet.new()
    end

    test "20 mixed outline mutations keep the state vector's client-id set bounded",
         %{store: store, root: root} do
      {:ok, uuid} = Outline.create("todo", root, store)
      {:ok, first} = Outline.add_item(store, uuid, %{text: "seed"})

      Enum.each(1..19, fn n ->
        assert {:ok, _id} = Outline.add_item(store, uuid, %{text: "item #{n}"})
      end)

      assert :ok = Outline.set_text(store, uuid, first, "renamed")

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, uuid)
      client_ids = sv_client_ids(doc)

      assert MapSet.size(client_ids) <= 2,
             "expected a bounded (<=2) set of client ids after 20 mutations, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)}"
    end
  end
end
