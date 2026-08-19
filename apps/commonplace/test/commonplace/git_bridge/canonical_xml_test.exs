defmodule Commonplace.GitBridge.CanonicalXmlTest do
  use ExUnit.Case, async: true

  alias Commonplace.GitBridge.CanonicalXml

  test "empty tree encodes to just a trailing newline" do
    assert {:ok, "\n"} = CanonicalXml.encode([])
  end

  test "single self-closing element with no children" do
    tree = [{:element, "br", %{}, []}]
    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == "<br/>\n"
  end

  test "element with attributes self-closes with sorted attrs" do
    tree = [{:element, "item", %{"z" => "1", "a" => "2", "m" => "3"}, []}]
    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == ~s(<item a="2" m="3" z="1"/>\n)
  end

  test "attribute order is byte-stable regardless of map construction order" do
    attrs_a = %{"z" => "1", "a" => "2", "m" => "3", "q" => "4"}
    attrs_b = %{"q" => "4", "m" => "3", "z" => "1", "a" => "2"}

    tree_a = [{:element, "item", attrs_a, []}]
    tree_b = [{:element, "item", attrs_b, []}]

    assert CanonicalXml.encode(tree_a) == CanonicalXml.encode(tree_b)
  end

  test "map-ordering-hostile attribute set (10+ keys) is byte-identical across construction orders" do
    keys = for i <- 1..15, do: "attr#{i}"

    attrs_a = keys |> Enum.map(&{&1, "v#{&1}"}) |> Map.new()
    attrs_b = keys |> Enum.reverse() |> Enum.map(&{&1, "v#{&1}"}) |> Map.new()

    tree_a = [{:element, "row", attrs_a, []}]
    tree_b = [{:element, "row", attrs_b, []}]

    {:ok, out_a} = CanonicalXml.encode(tree_a)
    {:ok, out_b} = CanonicalXml.encode(tree_b)

    assert out_a == out_b
    # confirm sorted order landed in the string
    sorted_keys = Enum.sort(keys)
    positions = Enum.map(sorted_keys, fn k -> :binary.match(out_a, k) |> elem(0) end)
    assert positions == Enum.sort(positions)
  end

  test "element-only children are pretty-printed with 2-space indent, one per line" do
    tree = [
      {:element, "ul", %{},
       [
         {:element, "li", %{}, []},
         {:element, "li", %{}, []}
       ]}
    ]

    assert {:ok, out} = CanonicalXml.encode(tree)

    assert out == """
           <ul>
             <li/>
             <li/>
           </ul>
           """
  end

  test "deeply nested element-only trees indent each level" do
    tree = [
      {:element, "a", %{},
       [
         {:element, "b", %{},
          [
            {:element, "c", %{}, []}
          ]}
       ]}
    ]

    assert {:ok, out} = CanonicalXml.encode(tree)

    assert out == """
           <a>
             <b>
               <c/>
             </b>
           </a>
           """
  end

  test "single text-only child renders inline, not indented" do
    tree = [{:element, "p", %{}, [{:text, "hello"}]}]

    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == "<p>hello</p>\n"
  end

  test "mixed text+element children stay inline in document order, no reflow" do
    tree = [
      {:element, "p", %{},
       [
         {:text, "Hello "},
         {:element, "b", %{}, [{:text, "world"}]},
         {:text, "!"}
       ]}
    ]

    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == "<p>Hello <b>world</b>!</p>\n"
  end

  test "mixed content poisons descendants: element-only grandchildren stay inline too" do
    tree = [
      {:element, "p", %{},
       [
         {:text, "see "},
         {:element, "b", %{},
          [
            {:element, "i", %{}, [{:text, "here"}]}
          ]}
       ]}
    ]

    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == "<p>see <b><i>here</i></b></p>\n"
  end

  test "text escaping: ampersand, less-than, greater-than in text content" do
    tree = [{:element, "p", %{}, [{:text, "a & b < c > d"}]}]

    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == "<p>a &amp; b &lt; c &gt; d</p>\n"
  end

  test "attribute escaping includes quote in addition to amp/lt/gt" do
    tree = [{:element, "item", %{"title" => ~s(say "hi" & <bye>)}, []}]

    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == ~s(<item title="say &quot;hi&quot; &amp; &lt;bye&gt;"/>\n)
  end

  test "unicode content passes through unescaped" do
    tree = [{:element, "p", %{}, [{:text, "héllo wörld 日本語 🎉"}]}]

    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == "<p>héllo wörld 日本語 🎉</p>\n"
  end

  test "empty attributes map renders no attributes" do
    tree = [{:element, "div", %{}, []}]

    assert {:ok, out} = CanonicalXml.encode(tree)
    assert out == "<div/>\n"
  end

  test "fragment nodes are transparent in block mode" do
    tree = [
      {:fragment,
       [
         {:element, "a", %{}, []},
         {:element, "b", %{}, []}
       ]}
    ]

    assert {:ok, out} = CanonicalXml.encode(tree)

    assert out == """
           <a/>
           <b/>
           """
  end

  test "multiple root siblings render one after another" do
    tree = [
      {:element, "a", %{}, []},
      {:element, "b", %{}, []}
    ]

    assert {:ok, out} = CanonicalXml.encode(tree)

    assert out == """
           <a/>
           <b/>
           """
  end

  test "round-trip stability: encoding the same tree twice is byte-identical" do
    tree = [
      {:element, "item",
       %{"id" => "1", "collapsed" => "false", "parent" => "root", "order" => "a0"},
       [{:text, "first bullet"}]},
      {:element, "item",
       %{"id" => "2", "collapsed" => "false", "parent" => "root", "order" => "a1"},
       [{:text, "second bullet"}]}
    ]

    assert CanonicalXml.encode(tree) == CanonicalXml.encode(tree)
  end

  test "unserializable tree returns {:error, reason}" do
    tree = [{:not_a_real_node, "garbage"}]

    assert {:error, _reason} = CanonicalXml.encode(tree)
  end

  test "unserializable nested content (non-binary tag) returns {:error, reason}" do
    tree = [{:element, :not_a_string, %{}, []}]

    assert {:error, _reason} = CanonicalXml.encode(tree)
  end
end
