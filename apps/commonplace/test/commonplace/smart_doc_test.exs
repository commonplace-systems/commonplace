defmodule Commonplace.SmartDocTest do
  use ExUnit.Case, async: true

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
end
