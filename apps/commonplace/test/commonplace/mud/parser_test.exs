defmodule Commonplace.MUD.ParserTest do
  use ExUnit.Case, async: true

  alias Commonplace.MUD.Parser
  alias Commonplace.MUD.Parser.Command

  describe "parse/1" do
    test "empty input returns empty verb" do
      assert %Command{verb: ""} = Parser.parse("")
      assert %Command{verb: ""} = Parser.parse("   ")
    end

    test "single-word command" do
      assert %Command{verb: "look", args: "", argv: [], target: nil} = Parser.parse("look")
    end

    test "verb with target" do
      cmd = Parser.parse("take cloak")
      assert cmd.verb == "take"
      assert cmd.target == "cloak"
      assert cmd.argv == ["cloak"]
      assert cmd.args == "cloak"
    end

    test "verb with multi-word args preserves raw and splits argv" do
      cmd = Parser.parse("say hello there friends")
      assert cmd.verb == "say"
      assert cmd.args == "hello there friends"
      assert cmd.argv == ["hello", "there", "friends"]
      assert cmd.target == "hello"
    end

    test "leading-tick shortcut is say" do
      cmd = Parser.parse("'hello there")
      assert cmd.verb == "say"
      assert cmd.args == "hello there"
    end

    test "direction aliases normalize" do
      assert Parser.parse("n").verb == "north"
      assert Parser.parse("s").verb == "south"
      assert Parser.parse("e").verb == "east"
      assert Parser.parse("w").verb == "west"
      assert Parser.parse("u").verb == "up"
      assert Parser.parse("d").verb == "down"
    end

    test "inventory aliases normalize" do
      assert Parser.parse("i").verb == "inventory"
      assert Parser.parse("inv").verb == "inventory"
      assert Parser.parse("l").verb == "look"
    end

    test "verb is lowercased" do
      assert Parser.parse("LOOK").verb == "look"
      assert Parser.parse("Take cloak").verb == "take"
    end
  end

  describe "opposite_direction/1" do
    test "cardinal pairs" do
      assert Parser.opposite_direction("north") == "south"
      assert Parser.opposite_direction("south") == "north"
      assert Parser.opposite_direction("east") == "west"
      assert Parser.opposite_direction("west") == "east"
      assert Parser.opposite_direction("up") == "down"
      assert Parser.opposite_direction("down") == "up"
      assert Parser.opposite_direction("in") == "out"
      assert Parser.opposite_direction("out") == "in"
    end

    test "unknown direction is nil" do
      assert Parser.opposite_direction("widdershins") == nil
    end
  end

  describe "direction?/1" do
    test "recognizes cardinals" do
      for dir <- ["north", "south", "east", "west", "up", "down", "in", "out"] do
        assert Parser.direction?(dir)
      end
    end

    test "rejects non-directions" do
      refute Parser.direction?("look")
      refute Parser.direction?("take")
    end
  end
end
