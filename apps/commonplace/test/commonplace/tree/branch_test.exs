defmodule Commonplace.Tree.BranchTest do
  @moduledoc """
  Tests for branch activate/deactivate (sparse sync).
  """
  use ExUnit.Case

  alias Commonplace.Tree.Schema

  describe "sync flag" do
    test "entries default to sync:true" do
      doc =
        Schema.new_schema()
        |> Schema.add_directory("main", "uuid-main")

      {:ok, entry} = Schema.get_entry(doc, "main")
      assert entry.sync == true
    end

    test "deactivate sets sync:false" do
      doc =
        Schema.new_schema()
        |> Schema.add_directory("feature", "uuid-feature")
        |> Schema.deactivate("feature")

      {:ok, entry} = Schema.get_entry(doc, "feature")
      assert entry.sync == false
      assert entry.node_id == "uuid-feature"
      assert entry.type == :dir
    end

    test "activate sets sync:true" do
      doc =
        Schema.new_schema()
        |> Schema.add_directory("feature", "uuid-feature")
        |> Schema.deactivate("feature")
        |> Schema.activate("feature")

      {:ok, entry} = Schema.get_entry(doc, "feature")
      assert entry.sync == true
    end

    test "entries map includes sync field" do
      doc =
        Schema.new_schema()
        |> Schema.add_directory("active", "uuid-a")
        |> Schema.add_directory("inactive", "uuid-i")
        |> Schema.deactivate("inactive")

      entries = Schema.entries(doc)
      assert entries["active"]["sync"] == true
      assert entries["inactive"]["sync"] == false
    end

    test "list_entries includes sync field" do
      doc =
        Schema.new_schema()
        |> Schema.add_directory("main", "uuid-main")
        |> Schema.add_directory("dev", "uuid-dev")
        |> Schema.deactivate("dev")

      entries = Schema.list_entries(doc)
      main = Enum.find(entries, &(&1.name == "main"))
      dev = Enum.find(entries, &(&1.name == "dev"))

      assert main.sync == true
      assert dev.sync == false
    end

    test "deactivating a nonexistent entry is a no-op" do
      doc = Schema.new_schema()
      doc2 = Schema.deactivate(doc, "nonexistent")
      assert Schema.entries(doc2) == Schema.entries(doc)
    end

    test "sync flag survives commit/reconstruct roundtrip" do
      doc =
        Schema.new_schema()
        |> Schema.add_directory("active", "uuid-a")
        |> Schema.add_directory("inactive", "uuid-i")
        |> Schema.deactivate("inactive")

      update = Yelixer.Encoding.encode_update(doc)
      doc2 = Schema.new_schema()
      {:ok, doc2} = Yelixer.Encoding.apply_update(doc2, update)

      {:ok, active} = Schema.get_entry(doc2, "active")
      {:ok, inactive} = Schema.get_entry(doc2, "inactive")
      assert active.sync == true
      assert inactive.sync == false
    end
  end
end
