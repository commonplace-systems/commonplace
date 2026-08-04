defmodule Commonplace.BlackTest do
  @moduledoc """
  CX-o1l9 (Black M1) test pins 1-3 + 5 from
  `docs/plans/2026-07-06-black-m1-build-spec.md` §5:

    1. `select/3` glob semantics, deterministic order, depth/limit caps.
    2. `json/2` + `xml/2` round canonical renders.
    3. The receipts worked example ("open invoices" filter).
    5. `emit_red/2` tagged-signal delivery to a red subscriber.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Black
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_black_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    store_name = :"commit_store_black_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name}
  end

  defp mint_dir(store, parent_uuid, name) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(dir_doc)
    CommitStore.create_commit(store, dir_uuid, update, nil)

    parent_doc = load_schema(store, parent_uuid)
    parent_doc = Schema.add_directory(parent_doc, name, dir_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))

    dir_uuid
  end

  defp mint_text_file(store, parent_uuid, name, content) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)

    parent_doc = load_schema(store, parent_uuid)
    parent_doc = Schema.add_file(parent_doc, name, file_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))

    file_uuid
  end

  defp mint_map_file(store, parent_uuid, name, kvs) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, name)

    doc =
      Enum.reduce(kvs, doc, fn {k, v}, acc -> ContentType.set_key(acc, k, v) end)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)

    parent_doc = load_schema(store, parent_uuid)
    parent_doc = Schema.add_file(parent_doc, name, file_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))

    file_uuid
  end

  defp mint_xml_file(store, parent_uuid, name) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :xml, name)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)

    parent_doc = load_schema(store, parent_uuid)
    parent_doc = Schema.add_file(parent_doc, name, file_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))

    file_uuid
  end

  defp latest(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} -> commit.id
      _ -> nil
    end
  end

  defp load_schema(store, uuid) do
    case Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp mint_root(store) do
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)
    root_uuid
  end

  describe "select/3 glob semantics" do
    test "literal segment matches exactly", %{store: store} do
      root = mint_root(store)
      a = mint_text_file(store, root, "a.txt", "A")
      _b = mint_text_file(store, root, "b.txt", "B")

      assert [%{path: "a.txt", uuid: ^a}] = Black.select(root, "a.txt", store: store)
    end

    test "`*` matches within one segment only", %{store: store} do
      root = mint_root(store)
      sub = mint_dir(store, root, "sub")
      f1 = mint_text_file(store, root, "note1.txt", "x")
      f2 = mint_text_file(store, root, "note2.txt", "y")
      _nested = mint_text_file(store, sub, "note3.txt", "z")

      results = Black.select(root, "note*.txt", store: store)
      uuids = Enum.map(results, & &1.uuid) |> Enum.sort()
      assert uuids == Enum.sort([f1, f2])
    end

    test "`**` matches any depth including zero", %{store: store} do
      root = mint_root(store)
      invoices = mint_dir(store, root, "invoices")
      sub = mint_dir(store, invoices, "2026")

      top = mint_map_file(store, invoices, "top.json", %{"status" => "open"})
      deep = mint_map_file(store, sub, "deep.json", %{"status" => "open"})

      results = Black.select(root, "invoices/**/*.json", store: store)
      uuids = Enum.map(results, & &1.uuid) |> Enum.sort()
      assert uuids == Enum.sort([top, deep])
    end

    test "`?` and character classes match single characters", %{store: store} do
      root = mint_root(store)
      a = mint_text_file(store, root, "a1.txt", "x")
      b = mint_text_file(store, root, "ab.txt", "y")

      assert [%{uuid: ^a}] = Black.select(root, "a[0-9].txt", store: store)

      results = Black.select(root, "a?.txt", store: store) |> Enum.map(& &1.uuid) |> Enum.sort()
      assert results == Enum.sort([a, b])
    end

    test "deterministic order across repeated calls", %{store: store} do
      root = mint_root(store)
      mint_text_file(store, root, "m.txt", "1")
      mint_text_file(store, root, "z.txt", "2")
      mint_text_file(store, root, "a.txt", "3")

      run1 = Black.select(root, "*.txt", store: store) |> Enum.map(& &1.path)
      run2 = Black.select(root, "*.txt", store: store) |> Enum.map(& &1.path)
      assert run1 == run2
    end

    test "empty result on no match", %{store: store} do
      root = mint_root(store)
      mint_text_file(store, root, "a.txt", "x")

      assert Black.select(root, "nope/*.json", store: store) == []
      assert Black.select(root, "*.json", store: store) == []
    end

    test "max_depth caps how deep the walk descends", %{store: store} do
      root = mint_root(store)
      l1 = mint_dir(store, root, "l1")
      l2 = mint_dir(store, l1, "l2")
      _deep = mint_text_file(store, l2, "deep.txt", "x")

      # depth 0 = root; l1 is depth 1; l2 is depth 2. max_depth: 1 means
      # we never descend into l2, so the file below it can't match.
      assert Black.select(root, "**/*.txt", store: store, max_depth: 1) == []
      assert [_] = Black.select(root, "**/*.txt", store: store, max_depth: 5)
    end

    test "limit caps the number of matches collected", %{store: store} do
      root = mint_root(store)
      for i <- 1..20, do: mint_text_file(store, root, "f#{i}.txt", "x")

      results = Black.select(root, "*.txt", store: store, limit: 5)
      assert length(results) == 5
    end

    test "with_dirs: true also returns every visited directory schema uuid", %{store: store} do
      root = mint_root(store)
      sub = mint_dir(store, root, "sub")
      _f = mint_text_file(store, sub, "leaf.txt", "x")

      {matches, dirs} = Black.select(root, "sub/*.txt", store: store, with_dirs: true)
      assert length(matches) == 1
      assert MapSet.member?(dirs, root)
      assert MapSet.member?(dirs, sub)
    end
  end

  describe "with_truncation: true (CX-vt9l.6 — honest scan signal)" do
    # NON-VACUOUSNESS NOTE: each pair below asserts BOTH the positive
    # (a corpus that genuinely exceeds the cap reports truncated) and
    # the complementary negative (a corpus well under the cap reports
    # :none) against the SAME code path with only the corpus size (or
    # cap) changed — a hard-coded `truncated: :none` would fail the
    # positive case, and a hard-coded truncated map would fail the
    # negative case, so no constant answer satisfies both.

    test "default (no opt) return shape is byte-for-byte unchanged", %{store: store} do
      root = mint_root(store)
      a = mint_text_file(store, root, "a.txt", "x")

      assert [%{path: "a.txt", uuid: ^a}] = Black.select(root, "a.txt", store: store)
    end

    test "LIMIT: a corpus exceeding a small limit reports truncated (limit: true)", %{
      store: store
    } do
      root = mint_root(store)
      for i <- 1..20, do: mint_text_file(store, root, "f#{i}.txt", "x")

      result = Black.select(root, "*.txt", store: store, limit: 5, with_truncation: true)

      assert length(result.matches) == 5
      assert %{limit: true, depth: []} = result.truncated
    end

    test "LIMIT: the same corpus under a generous limit reports complete (:none)", %{
      store: store
    } do
      root = mint_root(store)
      for i <- 1..20, do: mint_text_file(store, root, "f#{i}.txt", "x")

      result = Black.select(root, "*.txt", store: store, limit: 1_000, with_truncation: true)

      assert length(result.matches) == 20
      assert result.truncated == :none
    end

    test "DEPTH (the sharp case — hit COUNT alone cannot reveal this): matches nested deeper than a small max_depth report depth-truncation",
         %{store: store} do
      root = mint_root(store)
      l1 = mint_dir(store, root, "l1")
      l2 = mint_dir(store, l1, "l2")
      _deep = mint_text_file(store, l2, "deep.txt", "x")

      result = Black.select(root, "**/*.txt", store: store, max_depth: 1, with_truncation: true)

      # The hit count is 0 either way a caller could imagine ("capped"
      # or "genuinely nothing below root") — only `truncated` tells
      # them a directory was skipped rather than empty.
      assert result.matches == []
      assert %{limit: false, depth: depth} = result.truncated
      assert depth != []
      assert "l1/l2" in depth
    end

    test "DEPTH: the same tree under a generous max_depth reports complete (:none)", %{
      store: store
    } do
      root = mint_root(store)
      l1 = mint_dir(store, root, "l1")
      l2 = mint_dir(store, l1, "l2")
      deep = mint_text_file(store, l2, "deep.txt", "x")

      result = Black.select(root, "**/*.txt", store: store, max_depth: 5, with_truncation: true)

      assert [%{uuid: ^deep}] = result.matches
      assert result.truncated == :none
    end

    test "COMPLETE: a small corpus fully scanned under generous caps reports explicit :none, not merely a missing flag",
         %{store: store} do
      root = mint_root(store)
      mint_text_file(store, root, "a.txt", "x")
      mint_text_file(store, root, "b.txt", "y")

      result = Black.select(root, "*.txt", store: store, with_truncation: true)

      assert length(result.matches) == 2
      assert Map.has_key?(result, :truncated)
      assert result.truncated == :none
    end

    test "with_truncation composes with with_pin: map carries both pin and truncated", %{
      store: store
    } do
      root = mint_root(store)
      for i <- 1..5, do: mint_text_file(store, root, "f#{i}.txt", "x")

      result =
        Black.select(root, "*.txt", store: store, limit: 2, with_truncation: true, with_pin: true)

      assert length(result.matches) == 2
      assert is_map(result.pin)
      assert %{limit: true} = result.truncated
    end
  end

  describe "json/2 and xml/2" do
    test "json/2 round-trips a map doc through canonical JSON", %{store: store} do
      root = mint_root(store)
      uuid = mint_map_file(store, root, "doc.json", %{"status" => "open", "amount" => 42})

      assert {:ok, decoded} = Black.json(uuid, store: store)
      assert decoded == %{"status" => "open", "amount" => 42}
    end

    test "json/2 returns :not_found for an uncommitted uuid", %{store: store} do
      assert {:error, :not_found} = Black.json(UUID.uuid4(), store: store)
    end

    test "xml/2 round-trips an (empty) xml doc through canonical XML", %{store: store} do
      root = mint_root(store)
      uuid = mint_xml_file(store, root, "doc.xml")

      assert {:ok, xml_string} = Black.xml(uuid, store: store)
      assert is_binary(xml_string)
    end

    test "xml/2 returns :not_found for an uncommitted uuid", %{store: store} do
      assert {:error, :not_found} = Black.xml(UUID.uuid4(), store: store)
    end

    test "json/2 returns :not_a_content_doc for a schema/directory doc (CX-vt9l.5)", %{
      store: store
    } do
      root = mint_root(store)
      dir_uuid = mint_dir(store, root, "subdir")

      assert {:error, :not_a_content_doc} = Black.json(dir_uuid, store: store)
    end

    test "xml/2 returns :not_a_content_doc for a schema/directory doc (CX-vt9l.5)", %{
      store: store
    } do
      root = mint_root(store)
      dir_uuid = mint_dir(store, root, "subdir")

      assert {:error, :not_a_content_doc} = Black.xml(dir_uuid, store: store)
    end

    test "json/2 distinguishes a genuinely empty map doc from a schema doc (CX-vt9l.5)", %{
      store: store
    } do
      root = mint_root(store)
      empty_map_uuid = mint_map_file(store, root, "empty.json", %{})

      assert {:ok, %{}} = Black.json(empty_map_uuid, store: store)
    end

    test "xml/2 distinguishes a genuinely empty xml doc from a schema doc (CX-vt9l.5)", %{
      store: store
    } do
      root = mint_root(store)
      empty_xml_uuid = mint_xml_file(store, root, "empty.xml")

      assert {:ok, xml_string} = Black.xml(empty_xml_uuid, store: store)
      assert is_binary(xml_string)
    end
  end

  describe "receipts worked example (spec §1)" do
    test "open-invoice filter via select |> Enum.filter(json)", %{store: store} do
      root = mint_root(store)
      invoices = mint_dir(store, root, "invoices")
      y2026 = mint_dir(store, invoices, "2026")

      open1 = mint_map_file(store, invoices, "inv-1.json", %{"status" => "open"})
      _closed1 = mint_map_file(store, invoices, "inv-2.json", %{"status" => "closed"})
      open2 = mint_map_file(store, y2026, "inv-3.json", %{"status" => "open"})
      _closed2 = mint_map_file(store, y2026, "inv-4.json", %{"status" => "closed"})

      open_invoices =
        Black.select(root, "invoices/**/*.json", store: store)
        |> Enum.filter(fn m ->
          {:ok, inv} = Black.json(m.uuid, store: store)
          inv["status"] == "open"
        end)
        |> Enum.map(& &1.uuid)
        |> Enum.sort()

      assert open_invoices == Enum.sort([open1, open2])
    end
  end

  describe "emit_red/2" do
    test "a red subscriber receives the tagged signal", %{store: _store} do
      uuid = UUID.uuid4()
      CPPubSub.subscribe_red(uuid)

      assert :ok = Black.emit_red(uuid, %{kind: :test_signal, n: 1})

      topic = "red:#{uuid}"
      assert_receive {^topic, {:black, :signal, %{source: pid, payload: payload}}}
      assert pid == self()
      assert payload == %{kind: :test_signal, n: 1}
    end
  end
end
