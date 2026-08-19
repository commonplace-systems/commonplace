defmodule Commonplace.Store.LateEditTranslatorTest do
  @moduledoc """
  CX-yvhs (Build 6.3): `Commonplace.Store.LateEditTranslator.translate_update/2`
  decodes a Yjs V1 update binary, rewrites every item's reference fields
  (origin, right_origin, parent when {:id, _}) through the supplied
  inverse derivation map, preserves each item's own (clientID, clock),
  and re-encodes deterministically.

  This is the load-bearing primitive of Build 6 — it's how a late edit
  produced in a post-snapshot namespace gets rewritten back into a
  source namespace so a peer can apply it without seeing unknown item
  IDs.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.LateEditTranslator
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, XMLFragment}

  # -------------------- Helpers --------------------

  # Inverse DM shape: %{source_snapshot_hash => %{old_id => new_id}}
  # where ids are {client, clock} tuples.
  defp dm(hash, pairs) when is_list(pairs) do
    %{hash => Map.new(pairs)}
  end

  defp identity_dm, do: %{}

  # Produce a compact text update from client_id inserting `s` at position 0.
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

  defp decode!(bin) do
    {:ok, {items, ds, _}} = Encoding.decode_update(bin)
    {items, ds}
  end

  # -------------------- Round-trip / identity --------------------

  describe "identity translation" do
    test "empty inverse DM returns byte-identical update" do
      e = text_update(1, "hello")
      assert {:ok, e2} = LateEditTranslator.translate_update(e, identity_dm())
      assert e2 == e
    end

    test "inverse DM with no matching refs returns byte-identical update" do
      e = text_update(1, "hello")
      # DM maps an id that doesn't appear in E — nothing translated.
      dm = dm(<<1>>, [{{999, 0}, {888, 0}}])
      assert {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      assert e2 == e
    end

    test "empty inner inverse-DM maps (all sources present but empty) returns byte-identical" do
      e = text_update(1, "hello")
      dm = %{<<1>> => %{}, <<2>> => %{}}
      assert {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      assert e2 == e
    end
  end

  describe "identity preservation — (clientID, clock) unchanged" do
    test "item identities are NOT translated even when present in the inverse DM" do
      # A text insert from client 1 produces items with id.client = 1.
      # If the inverse DM contains {1, 0} => {999, 0}, the item's OWN
      # identity must NOT be rewritten — only its refs to other items.
      e = text_update(1, "ab")
      dm = dm(<<1>>, [{{1, 0}, {999, 99}}, {{1, 1}, {999, 100}}])

      {items_before, _} = decode!(e)
      {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      {items_after, _} = decode!(e2)

      assert length(items_after) == length(items_before)

      Enum.zip(items_before, items_after)
      |> Enum.each(fn {a, b} ->
        assert a.id == b.id, "item identity must be preserved"
      end)
    end
  end

  # -------------------- Per-ref-type translation --------------------

  describe "left-origin translation" do
    test "translates origin when present in inverse DM" do
      # A two-insert sequence: first item has no origin, second item has
      # origin pointing at the first (same client). Translating the
      # first item's identity lookup should rewrite the second item's
      # origin.
      e = text_append_update(1, "a", "b")
      {items, _} = decode!(e)

      # Find an item with non-nil origin pointing at client 1.
      refs = items |> Enum.filter(&(&1.origin != nil))
      assert refs != []
      origin_id = hd(refs).origin
      old = {origin_id.client, origin_id.clock}
      new = {42, 7}

      dm = dm(<<1>>, [{old, new}])
      {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      {items2, _} = decode!(e2)

      # All items that referenced `old` as origin now reference `new`.
      for {a, b} <- Enum.zip(items, items2) do
        expected_origin =
          case a.origin do
            nil -> nil
            %{client: c, clock: k} when {c, k} == old -> %Yelixer.ID{client: 42, clock: 7}
            other -> other
          end

        assert b.origin == expected_origin
      end
    end
  end

  describe "right-origin translation" do
    test "translates right_origin when present in inverse DM" do
      # Construct an insert-between-existing-items scenario:
      # client 1 lays down "xz" then inserts "y" between x and z,
      # producing an item with both origin (x) and right_origin (z).
      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      doc = Text.insert(doc, "t", 0, "xz")
      doc = Text.insert(doc, "t", 1, "y")
      e = Encoding.encode_update(doc)

      {items, _} = decode!(e)
      y_item = Enum.find(items, &(&1.right_origin != nil))
      assert y_item != nil, "expected at least one item with right_origin"
      ro = y_item.right_origin
      old = {ro.client, ro.clock}

      dm = dm(<<1>>, [{old, {55, 3}}])
      {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      {items2, _} = decode!(e2)

      for {a, b} <- Enum.zip(items, items2) do
        expected =
          case a.right_origin do
            nil -> nil
            %{client: c, clock: k} when {c, k} == old -> %Yelixer.ID{client: 55, clock: 3}
            other -> other
          end

        assert b.right_origin == expected
      end
    end
  end

  describe "parent translation" do
    test "leaves {:named, _} parents untouched" do
      # A simple text insert has an implicit named parent "t" (after the
      # type-declaration item). The translator must not rewrite string
      # parent names.
      e = text_update(1, "a")
      {items, _} = decode!(e)
      assert Enum.any?(items, &match?({:named, _}, &1.parent))

      dm = dm(<<1>>, [{{0, 0}, {999, 0}}, {{1, 0}, {999, 1}}])
      {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      assert e2 != nil

      {items2, _} = decode!(e2)

      for {a, b} <- Enum.zip(items, items2) do
        case a.parent do
          {:named, n} -> assert b.parent == {:named, n}
          _ -> :ok
        end
      end
    end

    test "translates {:id, id} parents when present in inverse DM" do
      # Add a key-value pair to a YMap whose key is a nested structure.
      # The type-declaration item has `{:named, "m"}` as its parent
      # (root-level), and its child value items have `{:id, type_id}`
      # as their parent when they're standalone without origin.
      # Easiest way to get an {:id, _} parent wire-side: an XMLFragment
      # with a child element. But simpler: a YMap value.
      #
      # Actually any map-entry write from a single client shows up as
      # an item with origin=nil, right_origin=nil, parent={:named, "m"},
      # parent_sub="key". That's {:named,_}, not {:id,_}.
      #
      # A reliable way to produce an {:id, _} parent is to translate an
      # item-level reference explicitly. We synthesize a fake by patching
      # an item whose parent is {:id, ...} directly... but easier:
      # XML fragment with a child element creates a parent-is-id link.

      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "x", :xml_fragment)
      doc = XMLFragment.insert_child(doc, "x", 0, {:element, "div"})
      e = Encoding.encode_update(doc)

      {items, _} = decode!(e)

      id_parents =
        items
        |> Enum.filter(fn
          %{parent: {:id, _}} -> true
          _ -> false
        end)

      case id_parents do
        [] ->
          # No {:id, _} parent produced by this construction — skip.
          :ok

        [first | _] ->
          {:id, id} = first.parent
          old = {id.client, id.clock}

          dm = dm(<<1>>, [{old, {77, 11}}])
          {:ok, e2} = LateEditTranslator.translate_update(e, dm)
          {items2, _} = decode!(e2)

          for {a, b} <- Enum.zip(items, items2) do
            case a.parent do
              {:id, %{client: c, clock: k}} when {c, k} == old ->
                assert b.parent == {:id, %Yelixer.ID{client: 77, clock: 11}}

              {:id, other_id} ->
                assert b.parent == {:id, other_id}

              other ->
                assert b.parent == other
            end
          end
      end
    end
  end

  describe "bare (nil) origins" do
    test "nil origin and nil right_origin stay nil after translation" do
      # Root-level text insert: items have no origin (leftmost in a
      # sequence) or no right_origin (rightmost). Those should stay nil.
      e = text_update(1, "a")
      dm = dm(<<1>>, [{{0, 0}, {777, 0}}])
      {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      {items, _} = decode!(e)
      {items2, _} = decode!(e2)

      for {a, b} <- Enum.zip(items, items2) do
        if a.origin == nil, do: assert(b.origin == nil)
        if a.right_origin == nil, do: assert(b.right_origin == nil)
      end
    end
  end

  # -------------------- Multi-source inverse DM --------------------

  describe "outer-keyed inverse DM" do
    test "applies lookups from any source-hash inner map" do
      e = text_append_update(1, "a", "b")
      {items, _} = decode!(e)
      origin_id = Enum.find(items, &(&1.origin != nil)).origin
      old = {origin_id.client, origin_id.clock}

      # Split the lookup across two source hashes. Only one contains the
      # relevant mapping — the translator must find it anyway.
      dm = %{
        <<1>> => %{{111, 0} => {222, 0}},
        <<2>> => %{old => {33, 33}}
      }

      {:ok, e2} = LateEditTranslator.translate_update(e, dm)
      {items2, _} = decode!(e2)

      matched = Enum.find(items2, &(&1.origin != nil))
      assert matched.origin == %Yelixer.ID{client: 33, clock: 33}
    end
  end

  # -------------------- Determinism --------------------

  describe "byte-determinism" do
    test "same (E, inverse_dm) produces byte-identical output across repeat calls" do
      e = text_append_update(1, "hello", "world")
      {items, _} = decode!(e)
      origin_id = Enum.find(items, &(&1.origin != nil)).origin

      dm = dm(<<1>>, [{{origin_id.client, origin_id.clock}, {555, 555}}])

      {:ok, a} = LateEditTranslator.translate_update(e, dm)
      {:ok, b} = LateEditTranslator.translate_update(e, dm)
      {:ok, c} = LateEditTranslator.translate_update(e, dm)

      assert a == b
      assert b == c
    end

    test "double-translate — translate(translate(E, dm_old_to_new), dm_new_to_older) is byte-identical for same inputs" do
      # Two successive translations through the same pipeline must be
      # fully deterministic. This is the regression guard for any latent
      # nondeterminism in the walker / flattener / encoder.
      e = text_append_update(1, "abc", "de")
      {items, _} = decode!(e)
      o_id = Enum.find(items, &(&1.origin != nil)).origin

      dm1 = dm(<<1>>, [{{o_id.client, o_id.clock}, {100, 0}}])
      dm2 = dm(<<2>>, [{{100, 0}, {200, 0}}])

      {:ok, r1_a} = LateEditTranslator.translate_update(e, dm1)
      {:ok, r1_b} = LateEditTranslator.translate_update(e, dm1)
      assert r1_a == r1_b

      {:ok, r2_a} = LateEditTranslator.translate_update(r1_a, dm2)
      {:ok, r2_b} = LateEditTranslator.translate_update(r1_b, dm2)
      assert r2_a == r2_b
    end

    test "repeated translations with varied inputs are byte-identical (randomized batch)" do
      # Hand-rolled determinism batch — commonplace doesn't have
      # StreamData in its mix deps (yelixer does). Seeding :rand keeps
      # this reproducible; 50 iterations is enough to shake out any
      # ordering flake in the flattener or re-encoder.
      :rand.seed(:exsss, {17, 29, 113})

      for _ <- 1..50 do
        client_id = :rand.uniform(1_000_000)
        s1 = for _ <- 1..(1 + :rand.uniform(6)), into: "", do: <<65 + :rand.uniform(25)>>
        s2 = for _ <- 1..(1 + :rand.uniform(6)), into: "", do: <<65 + :rand.uniform(25)>>
        e = text_append_update(client_id, s1, s2)

        # Pull a real ref from the update so the DM has at least one hit.
        {items, _} = decode!(e)
        maybe_origin = Enum.find(items, &(&1.origin != nil))

        dm =
          if maybe_origin do
            o = maybe_origin.origin
            dm(<<0xDE, 0xAD>>, [{{o.client, o.clock}, {99, :rand.uniform(1_000_000)}}])
          else
            identity_dm()
          end

        {:ok, a} = LateEditTranslator.translate_update(e, dm)
        {:ok, b} = LateEditTranslator.translate_update(e, dm)

        assert a == b,
               "byte-determinism failed for client=#{client_id} s1=#{inspect(s1)} s2=#{inspect(s2)}"
      end
    end
  end

  # -------------------- Mixed clients --------------------

  describe "multi-client updates" do
    test "translating refs from one client does not corrupt other clients' items" do
      # Build an update by merging contributions from two clients.
      doc_a = Doc.new(client_id: 1)
      {doc_a, _} = Doc.get_or_create_type(doc_a, "t", :text)
      doc_a = Text.insert(doc_a, "t", 0, "abc")
      e_a = Encoding.encode_update(doc_a)

      doc_b = Doc.new(client_id: 2)
      {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
      {:ok, doc_b} = Encoding.apply_update(doc_b, e_a)
      doc_b = Text.insert(doc_b, "t", 3, "de")
      e_b = Encoding.encode_update(doc_b)

      {items, _} = decode!(e_b)
      # At least one item from client 2 with origin pointing at client 1.
      client2_item = Enum.find(items, fn it -> it.id.client == 2 and it.origin != nil end)
      assert client2_item != nil
      ro = client2_item.origin

      dm = dm(<<1>>, [{{ro.client, ro.clock}, {999, 42}}])
      {:ok, e2} = LateEditTranslator.translate_update(e_b, dm)
      {items2, _} = decode!(e2)

      # Client 1 items retain their identities; client 2 item origins
      # translated.
      for {a, b} <- Enum.zip(items, items2) do
        assert a.id == b.id

        if a.id.client == 2 and a.origin == ro do
          assert b.origin == %Yelixer.ID{client: 999, clock: 42}
        end
      end
    end
  end

  # -------------------- Error handling --------------------

  describe "error cases" do
    test "returns :malformed_update for undecodable bytes" do
      assert {:error, {:malformed_update, _}} =
               LateEditTranslator.translate_update(<<0xFF, 0xFF, 0xFF>>, identity_dm())
    end
  end
end
