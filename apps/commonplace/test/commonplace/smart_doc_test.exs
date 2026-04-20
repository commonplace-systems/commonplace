defmodule Commonplace.SmartDocTest do
  use ExUnit.Case, async: false

  alias Commonplace.SmartDoc

  describe "__ports__/0" do
    test "returns all declared ports" do
      defmodule FullPorts do
        use Commonplace.SmartDoc

        @blue_inputs ["config", "schema"]
        @cyan_outputs ["output"]
        @red_inputs ["events"]
        @magenta_outputs ["alerts", "notifications"]
      end

      assert FullPorts.__ports__() == %{
               blue_inputs: ["config", "schema"],
               cyan_outputs: ["output"],
               red_inputs: ["events"],
               magenta_outputs: ["alerts", "notifications"]
             }
    end

    test "empty declarations default to empty lists" do
      defmodule EmptyPorts do
        use Commonplace.SmartDoc
      end

      assert EmptyPorts.__ports__() == %{
               blue_inputs: [],
               cyan_outputs: [],
               red_inputs: [],
               magenta_outputs: []
             }
    end

    test "partial declarations default missing to empty lists" do
      defmodule PartialPorts do
        use Commonplace.SmartDoc

        @blue_inputs ["config"]
      end

      assert PartialPorts.__ports__() == %{
               blue_inputs: ["config"],
               cyan_outputs: [],
               red_inputs: [],
               magenta_outputs: []
             }
    end

    test "multiple inputs are all present" do
      defmodule MultiInputs do
        use Commonplace.SmartDoc

        @blue_inputs ["alpha", "beta", "gamma"]
      end

      assert MultiInputs.__ports__().blue_inputs == ["alpha", "beta", "gamma"]
    end
  end

  describe "overridable callbacks" do
    test "handle_blue/2 can be overridden" do
      defmodule CustomBlue do
        use Commonplace.SmartDoc

        @blue_inputs ["config"]

        def handle_blue("config", doc), do: {:custom, doc}
      end

      assert CustomBlue.handle_blue("config", %{a: 1}) == {:custom, %{a: 1}}
    end

    test "handle_red/2 can be overridden" do
      defmodule CustomRed do
        use Commonplace.SmartDoc

        @red_inputs ["events"]

        def handle_red("events", event), do: {:got_event, event}
      end

      assert CustomRed.handle_red("events", :ping) == {:got_event, :ping}
    end

    test "default handle_blue/2 returns :ok" do
      defmodule DefaultCallbacks do
        use Commonplace.SmartDoc
      end

      assert DefaultCallbacks.handle_blue("any", %{}) == :ok
      assert DefaultCallbacks.handle_red("any", :event) == :ok
    end
  end

  describe "push_cyan/3 (CX-023)" do
    # Uses the application-default CommitStore + CommandRouter (started
    # by the test env's commonplace app). push_cyan/3 dispatches to the
    # default-name CommandRouter, so we exercise the same path the
    # production smart-doc emit goes through.
    test "applies a CRDT-aware diff (preserves unchanged regions)" do
      store = Commonplace.Store.CommitStore
      uuid = UUID.uuid4()

      doc = Yelixer.Doc.new()
      doc = Commonplace.Document.ContentType.create(doc, :text, "doc.txt")
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, "the quick brown fox")
      update = Yelixer.Encoding.encode_update(doc)
      Commonplace.Store.CommitStore.create_commit(store, uuid, update, nil)

      state = %{resolved_ports: %{"out" => uuid}}

      assert :ok = SmartDoc.push_cyan(state, "out", "the slow brown fox")

      {:ok, result} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, uuid)
      content = Commonplace.Document.ContentType.get_content(result)

      assert content == "the slow brown fox",
             "push_cyan should produce a clean diffed result, got #{inspect(content)}"

      # Diff path means only the changed region churns — applying the
      # exact same text twice should yield no functional change.
      assert :ok = SmartDoc.push_cyan(state, "out", "the slow brown fox")

      {:ok, result2} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, uuid)
      assert Commonplace.Document.ContentType.get_content(result2) == "the slow brown fox"
    end

    test "returns :error when docref is not in resolved_ports" do
      state = %{resolved_ports: %{"known" => UUID.uuid4()}}
      assert :error = SmartDoc.push_cyan(state, "unknown", "any content")
    end
  end
end
