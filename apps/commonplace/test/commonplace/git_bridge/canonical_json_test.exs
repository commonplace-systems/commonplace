defmodule Commonplace.GitBridge.CanonicalJsonTest do
  use ExUnit.Case, async: true

  alias Commonplace.GitBridge.CanonicalJson

  test "same map different key-insertion order produces byte-identical output" do
    a = %{"b" => 1, "a" => 2, "c" => 3}
    b = %{"c" => 3, "a" => 2, "b" => 1}

    assert CanonicalJson.encode(a) == CanonicalJson.encode(b)
  end

  test "nested maps and lists sort recursively" do
    term = %{
      "z" => %{"y" => 1, "x" => 2},
      "a" => [%{"n" => 2, "m" => 1}, %{"b" => 1, "a" => 2}]
    }

    out = CanonicalJson.encode(term)

    # keys within nested maps come out sorted
    assert out =~ ~r/"m".*"n"/s
    assert out =~ ~r/"x".*"y"/s
    assert out =~ ~r/"a".*"z"/s
  end

  test "scalars encode correctly" do
    term = %{"s" => "hello", "n" => 42, "f" => 1.5, "t" => true, "nil" => nil}
    out = CanonicalJson.encode(term)

    assert out =~ ~s("s": "hello")
    assert out =~ ~s("n": 42)
    assert out =~ ~s("f": 1.5)
    assert out =~ ~s("t": true)
    assert out =~ ~s("nil": null)
  end

  test "output ends with exactly one trailing newline" do
    out = CanonicalJson.encode(%{"a" => 1})
    assert String.ends_with?(out, "\n")
    refute String.ends_with?(out, "\n\n")
  end

  test "lists of scalars round-trip" do
    out = CanonicalJson.encode(%{"list" => [3, 1, 2]})
    assert out =~ "[\n"
    assert Jason.decode!(out) == %{"list" => [3, 1, 2]}
  end

  test "deterministic across repeated calls" do
    term = %{"x" => %{"a" => 1, "b" => [1, 2, %{"z" => 1, "a" => 2}]}}
    assert CanonicalJson.encode(term) == CanonicalJson.encode(term)
  end
end
