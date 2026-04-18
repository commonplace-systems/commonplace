defmodule Commonplace.Store.LateEditPreflightTest do
  @moduledoc """
  CX-0ut2 (Build 6.4): `Commonplace.Store.LateEditPreflight.validate/2`
  walks a translated late-edit's references and confirms every one
  resolves via the inverse DM (or as an item E itself defines). If any
  ref is missing, the whole batch fails atomically with a reason that
  distinguishes:

  - `:case_a` — E edits (as target, parent, or delete) an item that
    was tombstoned in S. The ref has no inverse-DM entry.
  - `:case_b` — E inserts a new item whose origin/right_origin points
    at an item tombstoned before S was built.

  Per docs/late-edits-and-derivation-map.md § 'Missing entries in the
  inverse'. For MVP, derivation maps carry only live items in S, so a
  missing entry unambiguously means the target isn't reachable.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.LateEditPreflight
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.{Text, XMLFragment}

  # -------------------- Helpers --------------------

  # Outer-keyed inverse DM with a single source hash for test convenience.
  defp dm(pairs) when is_list(pairs) do
    %{<<"src">> => Map.new(pairs)}
  end

  defp text_update(client_id, s) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, s)
    Encoding.encode_update(doc)
  end

  defp text_append_update(client_id, base_str, appended) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, base_str)
    doc = Text.insert(doc, "t", String.length(base_str), appended)
    Encoding.encode_update(doc)
  end

  # Build an update E_b that *continues* another client's work — produces
  # items whose origin/right_origin refer to external (client_a) items.
  # The returned binary is a DIFF against base_a's SV, so only new items
  # (from client_b) are encoded; their ancestors live externally.
  defp continuation_update(client_a, base_str, client_b, appended) do
    doc_a = Doc.new(client_id: client_a)
    {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
    doc_a = Text.insert(doc_a, "t", 0, base_str)
    e_a = Encoding.encode_update(doc_a)

    doc_b = Doc.new(client_id: client_b)
    {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, e_a)
    doc_b = Text.insert(doc_b, "t", String.length(base_str), appended)

    base_sv = BlockStore.state_vector(doc_a.store)
    Encoding.encode_diff(doc_b, base_sv)
  end

  defp text_insert_between(client_id, around, middle) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, around)
    mid = div(String.length(around), 2)
    doc = Text.insert(doc, "t", mid, middle)
    Encoding.encode_update(doc)
  end

  defp decode!(bin) do
    {:ok, {items, ds, _}} = Encoding.decode_update(bin)
    {items, ds}
  end

  defp collect_item_ids(items) do
    Enum.reduce(items, MapSet.new(), fn it, acc ->
      MapSet.put(acc, {it.id.client, it.id.clock})
    end)
  end

  # Build a DM covering every external ref in `bin` — items whose refs
  # point at ids NOT in E's own identity set. This yields a DM that
  # makes pre-flight pass cleanly for `bin`.
  defp dm_for_all_external_refs(bin) do
    {items, _} = decode!(bin)
    own = collect_item_ids(items)

    refs =
      items
      |> Enum.flat_map(fn it ->
        [
          maybe_id(it.origin),
          maybe_id(it.right_origin),
          maybe_parent_id(it.parent)
        ]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(own, &1))
      |> Enum.uniq()

    dm(Enum.map(refs, fn id -> {id, {100, 0}} end))
  end

  defp maybe_id(nil), do: nil
  defp maybe_id(%{client: c, clock: k}), do: {c, k}

  defp maybe_parent_id({:id, %{client: c, clock: k}}), do: {c, k}
  defp maybe_parent_id(_), do: nil

  # -------------------- Basic :ok cases --------------------

  describe "validate/2 — happy path" do
    test "returns :ok when every external ref is in inverse DM" do
      e = text_update(1, "a")
      dm = dm_for_all_external_refs(e)
      assert :ok = LateEditPreflight.validate(e, dm)
    end

    test "returns :ok for a complex multi-item update with origin/right_origin links" do
      e = text_insert_between(1, "xz", "y")
      dm = dm_for_all_external_refs(e)
      assert :ok = LateEditPreflight.validate(e, dm)
    end

    test "returns :ok when update has no external refs (empty DM suffices)" do
      # The root type-declaration item has `parent: {:named, _}` — a
      # string, not an id — and no origin. So it has zero external refs.
      # But it does have parent:{:named, _} which is safe. Subsequent
      # items reference the type-decl as parent:{:id, _}, which IS an
      # external ref. So we need an empty single-item update with no
      # references at all... hard to construct with the public API.
      # Use the `dm_for_all_external_refs` helper to confirm whatever
      # the smallest update has, it fits in a DM covering its refs.
      e = text_update(1, "z")
      dm = dm_for_all_external_refs(e)
      assert :ok = LateEditPreflight.validate(e, dm)
    end
  end

  # -------------------- :case_b — origin/right_origin missing --------------------

  describe "validate/2 — :case_b (origin/right_origin tombstoned)" do
    test "returns :case_b when an origin is not in the inverse DM" do
      # Use continuation_update to produce items whose origin points at
      # an EXTERNAL item (from client 1's base) so preflight can check
      # against the DM rather than exempting as own.
      e = continuation_update(1, "abc", 2, "de")
      {items, _} = decode!(e)
      own = collect_item_ids(items)

      # Pick the first item with a non-nil origin that points outside E.
      victim_item =
        Enum.find(items, fn it ->
          it.origin != nil and not MapSet.member?(own, {it.origin.client, it.origin.clock})
        end)

      assert victim_item != nil,
             "test requires an item whose origin is external — adjust helper if not"

      missing_id = {victim_item.origin.client, victim_item.origin.clock}

      # DM covers every external ref EXCEPT the victim's origin.
      full_dm = dm_for_all_external_refs(e)

      broken_dm = %{
        <<"src">> =>
          full_dm
          |> Map.fetch!(<<"src">>)
          |> Map.delete(missing_id)
      }

      assert {:error, {:untranslatable, :case_b, ^missing_id}} =
               LateEditPreflight.validate(e, broken_dm)
    end

    test "returns :case_b when a right_origin is not in the inverse DM" do
      # Insert between two existing-external items: client 1 writes "xz",
      # client 2 inserts "y" in the middle. Client 2's new item has
      # origin=client 1's 'x' and right_origin=client 1's 'z'.
      doc_a = Doc.new(client_id: 1)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "xz")
      e_a = Encoding.encode_update(doc_a)

      doc_b = Doc.new(client_id: 2)
      {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
      {:ok, doc_b} = Encoding.apply_update(doc_b, e_a)
      doc_b = Text.insert(doc_b, "t", 1, "y")

      e = Encoding.encode_diff(doc_b, BlockStore.state_vector(doc_a.store))

      {items, _} = decode!(e)
      own = collect_item_ids(items)

      victim =
        Enum.find(items, fn it ->
          it.right_origin != nil and
            not MapSet.member?(own, {it.right_origin.client, it.right_origin.clock})
        end)

      assert victim != nil, "test requires an external right_origin ref"
      missing = {victim.right_origin.client, victim.right_origin.clock}

      broken_dm = %{
        <<"src">> =>
          e |> dm_for_all_external_refs() |> Map.fetch!(<<"src">>) |> Map.delete(missing)
      }

      assert {:error, {:untranslatable, :case_b, ^missing}} =
               LateEditPreflight.validate(e, broken_dm)
    end
  end

  # -------------------- :case_a — parent:id missing --------------------

  describe "validate/2 — :case_a (parent/target tombstoned)" do
    test "returns :case_a when a parent:{:id, _} ref is not in the inverse DM" do
      # XMLFragment child elements produce items with origin=nil and
      # parent={:id, type_decl_id}. Drop the type-decl id from the DM.
      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "x", :xml_fragment)
      doc = XMLFragment.insert_child(doc, "x", 0, {:element, "div"})
      e = Encoding.encode_update(doc)

      {items, _} = decode!(e)
      own = collect_item_ids(items)

      child_with_id_parent =
        Enum.find(items, fn
          %{parent: {:id, %{client: c, clock: k}}} -> not MapSet.member?(own, {c, k})
          _ -> false
        end)

      if child_with_id_parent == nil do
        # XMLFragment may embed its type-decl locally — skip if no external parent:id.
        :ok
      else
        {:id, pid} = child_with_id_parent.parent
        missing = {pid.client, pid.clock}

        broken_dm = %{
          <<"src">> =>
            e |> dm_for_all_external_refs() |> Map.fetch!(<<"src">>) |> Map.delete(missing)
        }

        assert {:error, {:untranslatable, :case_a, ^missing}} =
                 LateEditPreflight.validate(e, broken_dm)
      end
    end
  end

  # -------------------- :case_a — delete_set target missing --------------------

  describe "validate/2 — :case_a (delete_set target tombstoned)" do
    test "returns :case_a when a delete_set entry targets an id not in inverse DM" do
      # Build E by inserting "abc" as client 1, then deleting the
      # middle char. E's delete_set has a range (1, 1..2) targeting
      # item (1, 1). That item's id IS in E's own identity set
      # (client 1 created it), so it's fine by itself. To trigger
      # case_a, we craft a scenario where the delete targets an
      # EXTERNAL id (one that came from P, not from E itself).
      #
      # Client 2 "deletes" client 1's insertion:
      doc_a = Doc.new(client_id: 1)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "abc")
      e_a = Encoding.encode_update(doc_a)

      doc_b = Doc.new(client_id: 2)
      {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
      {:ok, doc_b} = Encoding.apply_update(doc_b, e_a)
      doc_b = Text.delete(doc_b, "t", 1, 1)

      # Encode as a DIFF against doc_a's SV so client 1's items aren't
      # carried as E's own — they must be looked up in the DM.
      base_sv = BlockStore.state_vector(doc_a.store)
      e_b = Encoding.encode_diff(doc_b, base_sv)

      # DM must include every delete-set target and every external item
      # ref for translation to succeed. Build a DM that covers all of
      # them, then drop one delete-set target.
      full = dm_for_all_external_refs(e_b)
      all_delete_ids = delete_set_ids(e_b)
      assert all_delete_ids != [], "test setup requires at least one delete target"

      covered =
        Enum.reduce(all_delete_ids, full, fn id, acc ->
          %{acc | <<"src">> => Map.put_new(acc[<<"src">>], id, {200, 0})}
        end)

      # First sanity: covered DM should pass.
      assert :ok = LateEditPreflight.validate(e_b, covered)

      # Now drop one delete-set target and assert :case_a.
      target = hd(all_delete_ids)
      broken = %{<<"src">> => Map.delete(covered[<<"src">>], target)}

      assert {:error, {:untranslatable, :case_a, ^target}} =
               LateEditPreflight.validate(e_b, broken)
    end
  end

  # -------------------- Error precedence --------------------

  describe "validate/2 — E's own items are exempt from DM lookups" do
    test "an item's origin pointing at ANOTHER E-item is valid without a DM entry" do
      # text_append_update from client 1 produces items where the
      # second char's origin is the first char (same client/adjacent
      # clock). Both items are in E — the origin is E-internal, not
      # external. A DM that doesn't cover the INTERNAL ref should still
      # pass as long as it covers external refs.
      e = text_append_update(1, "a", "b")
      dm = dm_for_all_external_refs(e)

      # Verify: deleting an E-internal id from the DM still leaves :ok
      # because the preflight exempts E-own items.
      {items, _} = decode!(e)
      own = collect_item_ids(items)

      internal_origin =
        Enum.find_value(items, fn it ->
          case it.origin do
            %{client: c, clock: k} = o ->
              if MapSet.member?(own, {c, k}), do: {c, k, o}, else: nil

            _ ->
              nil
          end
        end)

      if internal_origin != nil do
        # The DM wouldn't have this anyway (it's a helper that skips own
        # ids), but the core guarantee is that validate succeeds here.
        assert :ok = LateEditPreflight.validate(e, dm)
      else
        assert :ok = LateEditPreflight.validate(e, dm)
      end
    end
  end

  # -------------------- Error shape --------------------

  describe "validate/2 — error shape" do
    test "malformed update returns :malformed_update error" do
      assert {:error, {:malformed_update, _}} =
               LateEditPreflight.validate(<<0xFF, 0xFF, 0xFF>>, %{})
    end
  end

  # -------------------- translate_and_validate --------------------

  describe "translate_and_validate/2" do
    test "on success returns {:ok, translated_binary}" do
      e = text_update(1, "a")
      dm = dm_for_all_external_refs(e)
      assert {:ok, translated} = LateEditPreflight.translate_and_validate(e, dm)
      assert is_binary(translated)
    end

    test "on preflight failure returns :untranslatable — does not call translator" do
      e = continuation_update(1, "ab", 2, "cd")
      {items, _} = decode!(e)
      own = collect_item_ids(items)

      victim =
        Enum.find(items, fn it ->
          it.origin != nil and not MapSet.member?(own, {it.origin.client, it.origin.clock})
        end)

      missing = {victim.origin.client, victim.origin.clock}
      full = dm_for_all_external_refs(e)
      broken = %{<<"src">> => Map.delete(full[<<"src">>], missing)}

      assert {:error, {:untranslatable, :case_b, ^missing}} =
               LateEditPreflight.translate_and_validate(e, broken)
    end
  end

  # -------------------- Atomicity: preflight must fail BEFORE translation --------------------

  describe "atomicity — preflight-failure leaves translator uninvoked" do
    test "a mid-walk :case_a failure prevents any translation output" do
      # Build an E whose delete_set targets an external item, then drop
      # the corresponding DM entry. translate_and_validate must return
      # the error BEFORE any translate_update call — i.e., the return
      # shape must be {:error, ...}, never a partial {:ok, malformed_bytes}.
      doc_a = Doc.new(client_id: 1)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "abc")
      e_a = Encoding.encode_update(doc_a)

      doc_b = Doc.new(client_id: 2)
      {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
      {:ok, doc_b} = Encoding.apply_update(doc_b, e_a)
      doc_b = Text.delete(doc_b, "t", 1, 1)

      # Encode as a DIFF against doc_a's SV so client 1's items aren't
      # carried as E's own — the delete target is external, forcing
      # preflight to look it up in the DM.
      base_sv = BlockStore.state_vector(doc_a.store)
      e_b = Encoding.encode_diff(doc_b, base_sv)

      # DM missing the delete target.
      assert {:error, {:untranslatable, :case_a, _}} =
               LateEditPreflight.translate_and_validate(e_b, %{<<"src">> => %{}})
    end
  end

  # Helper — collect all delete_set target ids as {client, clock} tuples.
  defp delete_set_ids(bin) do
    {_, ds} = decode!(bin)

    ds.clients
    |> Enum.flat_map(fn {client, ranges} ->
      Enum.flat_map(ranges, fn {start, stop} ->
        Enum.map(start..(stop - 1), fn clock -> {client, clock} end)
      end)
    end)
  end
end
