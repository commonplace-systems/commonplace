defmodule Commonplace.Document.DocRefTest do
  use ExUnit.Case

  alias Commonplace.Document.DocRef

  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @cid "a1b2c3d4e5f6"

  describe "new/2" do
    test "creates ref with UUID only" do
      ref = DocRef.new(@uuid)
      assert ref.uuid == @uuid
      assert ref.path == nil
      assert ref.cid == nil
    end

    test "creates ref with path and cid" do
      ref = DocRef.new(@uuid, path: "notes/todo.txt", cid: @cid)
      assert ref.path == "notes/todo.txt"
      assert ref.uuid == @uuid
      assert ref.cid == @cid
    end
  end

  describe "parse/1" do
    test "parses path:uuid@cid" do
      {:ok, ref} = DocRef.parse("notes/todo.txt:#{@uuid}@#{@cid}")
      assert ref.path == "notes/todo.txt"
      assert ref.uuid == @uuid
      assert ref.cid == @cid
    end

    test "parses path:uuid" do
      {:ok, ref} = DocRef.parse("notes/todo.txt:#{@uuid}")
      assert ref.path == "notes/todo.txt"
      assert ref.uuid == @uuid
      assert ref.cid == nil
    end

    test "parses :uuid (no path)" do
      {:ok, ref} = DocRef.parse(":#{@uuid}")
      assert ref.path == nil
      assert ref.uuid == @uuid
    end

    test "parses :uuid@cid" do
      {:ok, ref} = DocRef.parse(":#{@uuid}@#{@cid}")
      assert ref.path == nil
      assert ref.uuid == @uuid
      assert ref.cid == @cid
    end

    test "parses bare UUID" do
      {:ok, ref} = DocRef.parse(@uuid)
      assert ref.path == nil
      assert ref.uuid == @uuid
      assert ref.cid == nil
    end

    test "rejects invalid format" do
      assert {:error, :invalid_format} = DocRef.parse("not-a-uuid")
    end
  end

  describe "to_string/1" do
    test "formats with path and cid" do
      ref = DocRef.new(@uuid, path: "notes/todo.txt", cid: @cid)
      assert DocRef.to_string(ref) == "notes/todo.txt:#{@uuid}@#{@cid}"
    end

    test "formats with path, no cid" do
      ref = DocRef.new(@uuid, path: "notes/todo.txt")
      assert DocRef.to_string(ref) == "notes/todo.txt:#{@uuid}"
    end

    test "formats with no path" do
      ref = DocRef.new(@uuid)
      assert DocRef.to_string(ref) == ":#{@uuid}"
    end

    test "String.Chars protocol works" do
      ref = DocRef.new(@uuid, path: "test.txt")
      assert "#{ref}" == "test.txt:#{@uuid}"
    end
  end

  describe "roundtrip" do
    test "parse(to_string(ref)) == ref" do
      ref = DocRef.new(@uuid, path: "a/b/c.txt", cid: @cid)
      {:ok, parsed} = DocRef.parse(DocRef.to_string(ref))
      assert parsed.path == ref.path
      assert parsed.uuid == ref.uuid
      assert parsed.cid == ref.cid
    end

    test "roundtrip without path" do
      ref = DocRef.new(@uuid)
      {:ok, parsed} = DocRef.parse(DocRef.to_string(ref))
      assert parsed.uuid == ref.uuid
      assert parsed.path == nil
    end
  end

  describe "resolve/1" do
    test "resolves to UUID" do
      ref = DocRef.new(@uuid, path: "test.txt")
      assert {:ok, @uuid} = DocRef.resolve(ref)
    end
  end
end
