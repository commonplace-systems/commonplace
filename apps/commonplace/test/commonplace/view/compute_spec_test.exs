defmodule Commonplace.View.ComputeSpecTest do
  @moduledoc """
  CX-oui2 (sub-bead ii of CX-d819 M5): substrate-tier ComputeSpec
  parser + validator + interpreter.

  Joins Commonplace.View.ArgResolver (M3) in the View namespace.

  Spec format (per held #3): XML extending view-XML vocabulary.
  Pipeline (per held #4): enumerated kinds — decode_json_array,
  materialize, render. Render-fn (per held #2): function-reference-by-name
  with Code.ensure_loaded + :erlang.function_exported validation.

  Tests cover parse, validate (round-1 audit (I)), and interpret on
  both chat-shaped and non-chat synthetic specs (Anchor M).
  """
  use ExUnit.Case, async: true

  alias Commonplace.View.ComputeSpec

  @chat_spec_xml """
  <compute-spec schema="1">
    <pipeline>
      <step kind="decode_json_array"/>
      <step kind="materialize">
        <chains>
          <chain field="edit_of" semantics="latest_replaces"/>
          <chain field="tombstone_of" semantics="marks_deleted"/>
        </chains>
      </step>
      <step kind="render">
        <function module="Commonplace.Chat.ChatViewBuilder" name="build_view_xml"/>
      </step>
    </pipeline>
  </compute-spec>
  """

  describe "parse/1 — chat-shaped spec" do
    test "parses canonical chat compute spec into a typed struct" do
      assert {:ok, spec} = ComputeSpec.parse(@chat_spec_xml)

      assert is_list(spec.pipeline)
      assert length(spec.pipeline) == 3

      [decode, materialize, render] = spec.pipeline

      assert decode.kind == :decode_json_array

      assert materialize.kind == :materialize
      assert length(materialize.chains) == 2

      assert Enum.find(materialize.chains, &(&1.field == "edit_of")).semantics ==
               :latest_replaces

      assert Enum.find(materialize.chains, &(&1.field == "tombstone_of")).semantics ==
               :marks_deleted

      assert render.kind == :render
      assert render.module == Commonplace.Chat.ChatViewBuilder
      assert render.function == :build_view_xml
    end

    test "returns {:error, _} on malformed XML" do
      assert {:error, _} = ComputeSpec.parse("<not-closed>")
    end

    test "returns {:error, _} when root is not <compute-spec>" do
      assert {:error, reason} = ComputeSpec.parse("<view><pipeline/></view>")
      assert reason =~ "compute-spec" or reason =~ "root"
    end
  end

  describe "validate/1 — round-1 audit (I)" do
    test "passes when render-fn module loaded + function exported" do
      {:ok, spec} = ComputeSpec.parse(@chat_spec_xml)
      assert :ok = ComputeSpec.validate(spec)
    end

    test "fails when render-fn module is not loaded" do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render">
            <function module="Commonplace.NoSuchModule" name="nope"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      {:ok, spec} = ComputeSpec.parse(xml)
      assert {:error, reason} = ComputeSpec.validate(spec)
      assert reason =~ "Commonplace.NoSuchModule"
    end

    test "fails when render-fn function is not exported" do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render">
            <function module="Commonplace.Chat.ChatViewBuilder" name="not_a_real_function"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      {:ok, spec} = ComputeSpec.parse(xml)
      assert {:error, reason} = ComputeSpec.validate(spec)
      assert reason =~ "not_a_real_function"
    end
  end

  describe "interpret/3 — pipeline application" do
    test "decode_json_array → materialize → render produces chat view-XML" do
      {:ok, spec} = ComputeSpec.parse(@chat_spec_xml)

      raw_entries = [
        Jason.encode!(%{
          "id" => "msg-1",
          "ts" => "T0",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => "hello"
        })
      ]

      output = ComputeSpec.interpret(spec, raw_entries, %{room_name: "general"})

      # Output is the rendered view-XML string from ChatViewBuilder.
      assert output =~ "msg-1"
      assert output =~ "hello"
      assert output =~ ~s(name="general")
    end

    test "edit_of chain semantics applied (M2 :latest_replaces)" do
      {:ok, spec} = ComputeSpec.parse(@chat_spec_xml)

      raw_entries = [
        Jason.encode!(%{
          "id" => "m1",
          "ts" => "T0",
          "author_signer_id" => "a",
          "author_path" => "a.usr",
          "text" => "v1"
        }),
        Jason.encode!(%{
          "id" => "m1-edit",
          "ts" => "T1",
          "author_signer_id" => "a",
          "author_path" => "a.usr",
          "text" => "v2",
          "edit_of" => "m1"
        })
      ]

      output = ComputeSpec.interpret(spec, raw_entries, %{room_name: "general"})

      assert output =~ "v2"
      refute output =~ ">v1<"
    end

    test "tombstone_of chain semantics applied (M2 :marks_deleted)" do
      {:ok, spec} = ComputeSpec.parse(@chat_spec_xml)

      raw_entries = [
        Jason.encode!(%{
          "id" => "m1",
          "ts" => "T0",
          "author_signer_id" => "a",
          "author_path" => "a.usr",
          "text" => "secret"
        }),
        Jason.encode!(%{
          "id" => "m1-del",
          "ts" => "T1",
          "author_signer_id" => "a",
          "author_path" => "a.usr",
          "tombstone_of" => "m1"
        })
      ]

      output = ComputeSpec.interpret(spec, raw_entries, %{room_name: "general"})

      assert output =~ "[deleted]"
      refute output =~ ">secret<"
    end
  end

  describe "interpret/3 — Anchor M (non-chat synthetic)" do
    defmodule TestRenderer do
      @moduledoc false
      # M5 substrate render-fn calling convention: (input, room_name_string).
      # Same shape ChatViewBuilder.build_view_xml uses.
      def render_task_list(entries, room) do
        items = Enum.map_join(entries, ",", & &1["title"])
        "<task-list room=\"#{room}\">#{items}</task-list>"
      end
    end

    test "non-chat compute spec works the same shape" do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="decode_json_array"/>
          <step kind="materialize">
            <chains>
              <chain field="revises" semantics="latest_replaces"/>
            </chains>
          </step>
          <step kind="render">
            <function module="#{inspect(TestRenderer)}" name="render_task_list"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      {:ok, spec} = ComputeSpec.parse(xml)
      assert :ok = ComputeSpec.validate(spec)

      raw_entries = [
        Jason.encode!(%{"id" => "t1", "title" => "first"}),
        Jason.encode!(%{"id" => "t2", "title" => "second"})
      ]

      output = ComputeSpec.interpret(spec, raw_entries, %{room_name: "my-tasks"})

      assert output =~ "first"
      assert output =~ "second"
      assert output =~ "my-tasks"
      assert output =~ "<task-list"
    end
  end
end
