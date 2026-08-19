defmodule Commonplace.Document.ViewTransclusionTest do
  use ExUnit.Case, async: false

  alias Commonplace.Document.{ContentType, ViewTransclusion, ViewXml}
  alias Commonplace.Document.ViewXml.Node
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_vt_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_vt_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  # --- Helpers ---

  defp seed_text_doc(store, root, filename, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)

    root_doc = load_root_schema(store, root)
    root_doc = Schema.add_file(root_doc, filename, uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root, update, nil)

    uuid
  end

  defp load_root_schema(store, root) do
    case CommitStore.latest_commit(store, root) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp parse!(xml) do
    {:ok, node} = ViewXml.parse(xml)
    node
  end

  defp expand(node, ctx, extra_opts \\ []) do
    opts =
      [store: ctx.store, root_uuid: ctx.root]
      |> Keyword.merge(extra_opts)

    ViewTransclusion.expand(node, opts)
  end

  # --- Tests ---

  describe "expand/2 — no includes" do
    test "leaves a tree without includes untouched", ctx do
      view = parse!(~s(<view><entity kind="page"><body><text>hi</text></body></entity></view>))

      result = expand(view, ctx)

      assert result == view
    end
  end

  describe "expand/2 — substantive children" do
    test "does not overwrite an include whose children are already present", ctx do
      # Even though the target doc exists, since the include already has
      # children the resolver must leave them in place (respect inlined
      # content).
      _ = seed_text_doc(ctx.store, ctx.root, "note.txt", "should not appear")

      view =
        parse!(~s(<view><include from="note.txt"><text>pre-inlined</text></include></view>))

      result = expand(view, ctx)

      [include] = result.children
      assert include.tag == :include
      assert [%Node{tag: :text} = text_child] = include.children
      assert ViewXml.text_content(text_child) == "pre-inlined"
    end

    test "is idempotent — running expand twice yields the same tree", ctx do
      _ = seed_text_doc(ctx.store, ctx.root, "page.txt", "hello from page")

      view = parse!(~s(<view><include from="page.txt"/></view>))

      once = expand(view, ctx)
      twice = expand(once, ctx)

      assert once == twice
    end
  end

  describe "expand/2 — resolution against the in-memory store" do
    test "resolves an empty include to the target doc's content", ctx do
      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "included.view",
          ~s(<view><text>inlined content</text></view>)
        )

      view = parse!(~s(<view><include from="included.view"/></view>))

      result = expand(view, ctx)
      [include] = result.children
      assert include.tag == :include

      assert Enum.any?(include.children, fn
               %Node{tag: :text} = n -> ViewXml.text_content(n) == "inlined content"
               _ -> false
             end)
    end

    test "failed resolution when target does not exist yields an error child, does not raise",
         ctx do
      view = parse!(~s(<view><include from="missing.view"/></view>))

      result = expand(view, ctx)
      [include] = result.children
      assert include.tag == :include

      assert [%Node{tag: :text} = err] = include.children
      text = ViewXml.text_content(err)
      assert text =~ "not found" or text =~ "missing.view"
    end
  end

  describe "expand/2 — depth limits" do
    test "honors max_depth for chained includes", ctx do
      # Seed a chain: a.view -> b.view -> c.view -> d.view -> e.view
      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "e.view",
          ~s(<view><text>leaf</text></view>)
        )

      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "d.view",
          ~s(<view><include from="e.view"/></view>)
        )

      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "c.view",
          ~s(<view><include from="d.view"/></view>)
        )

      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "b.view",
          ~s(<view><include from="c.view"/></view>)
        )

      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "a.view",
          ~s(<view><include from="b.view"/></view>)
        )

      view = parse!(~s(<view><include from="a.view"/></view>))

      result = expand(view, ctx, max_depth: 2)

      # Walk the resolved tree. Somewhere inside, a chain should stop
      # at an error_child containing "depth limit reached".
      flat = flatten_text(result)
      assert flat =~ "depth limit reached"
    end
  end

  describe "expand/2 — cycle detection" do
    test "breaks a two-node cycle and emits a cycle warning", ctx do
      # Seed A and B first as empty, then update each to include the
      # other. The cycle is A -> B -> A.
      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "a.view",
          ~s(<view><include from="b.view"/></view>)
        )

      _ =
        seed_text_doc(
          ctx.store,
          ctx.root,
          "b.view",
          ~s(<view><include from="a.view"/></view>)
        )

      view = parse!(~s(<view><include from="a.view"/></view>))

      result = expand(view, ctx)

      flat = flatten_text(result)
      assert flat =~ "cycle"
    end
  end

  describe "expand/2 — plain text target" do
    test "wraps plain-text content in a <text format=\"plain\"> child", ctx do
      _ = seed_text_doc(ctx.store, ctx.root, "notes.txt", "plain body content")

      view = parse!(~s(<view><include from="notes.txt"/></view>))

      result = expand(view, ctx)
      [include] = result.children

      assert [%Node{tag: :text, attrs: attrs} = text] = include.children
      assert attrs["format"] == "plain"
      assert ViewXml.text_content(text) == "plain body content"
    end
  end

  # Recursively concatenate all binary/text children into a string so
  # tests can grep for marker substrings without caring about tree shape.
  defp flatten_text(%Node{children: children}) do
    children
    |> Enum.map_join(" ", fn
      %Node{} = n -> flatten_text(n)
      text when is_binary(text) -> text
    end)
  end
end
