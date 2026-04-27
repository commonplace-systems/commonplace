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
      assert {:ok, _} = ComputeSpec.validate(spec)
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
      assert {:ok, _} = ComputeSpec.validate(spec)

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

  # CX-7v9x (M6 sub-bead ii): <function ref="..." name="..."/> form
  # alongside the existing M5 <function module name> form. Mutex
  # validation: exactly one form per render step. M6 form resolves via
  # SourceDoc.resolve at validate-time.
  describe "M6 <function ref> syntax (CX-7v9x)" do
    alias Commonplace.Code.SourceDoc
    alias Commonplace.Document.ContentType
    alias Commonplace.Store.{CommitStore, CommitStoreClient}
    alias Commonplace.Tree.Schema

    setup do
      dir = Path.join(System.tmp_dir!(), "cp_compute_spec_m6_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      Application.put_env(:commonplace, :data_dir, dir)

      sup = Commonplace.Store.CommitStoreSupervisor
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()

      on_exit(fn ->
        _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
        _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
        Application.put_env(:commonplace, :data_dir, "tmp/test_data")

        {:ok, _pid} =
          Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

        Commonplace.Tree.DocCache.clear()
        SourceDoc.reset_cache()
        File.rm_rf!(dir)
      end)

      # Synthetic tree: /test/_compute (referenced by spec_path) +
      # /test/_renderer.ex (referenced by ../path)
      renderer_source = """
      defmodule Cp.Test.M6Renderer do
        def render(entries, room) do
          items = Enum.map_join(entries, ",", & &1["title"])
          "<list room=\\"\#{room}\\">\#{items}</list>"
        end
      end
      """

      renderer_uuid = UUID.uuid4()
      renderer_doc = Yelixer.Doc.new()
      renderer_doc = ContentType.create(renderer_doc, :text, "_renderer.ex")
      renderer_doc = ContentType.insert_text(renderer_doc, 0, renderer_source)
      update = Yelixer.Encoding.encode_update(renderer_doc)
      CommitStore.create_commit(Commonplace.Store.CommitStore, renderer_uuid, update, nil)

      dir_uuid = UUID.uuid4()
      dir_schema = Schema.new_schema()
      dir_schema = Schema.add_file(dir_schema, "_renderer.ex", renderer_uuid)
      update = Yelixer.Encoding.encode_update(dir_schema)
      CommitStore.create_commit(Commonplace.Store.CommitStore, dir_uuid, update, nil)

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_directory(root_doc, "test", dir_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
      File.write!(Path.join(dir, "root"), root_uuid)

      %{root_uuid: root_uuid, renderer_uuid: renderer_uuid, store: CommitStoreClient}
    end

    test "parse accepts <function ref name/> form" do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render">
            <function ref="../_renderer.ex" name="render"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      assert {:ok, spec} = ComputeSpec.parse(xml)
      [render] = spec.pipeline

      assert render.kind == :render
      assert render.ref == "../_renderer.ex"
      assert render.function == :render
    end

    test "parse rejects <function ref/> WITHOUT name (round-1: name required-always)" do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render"><function ref="../_renderer.ex"/></step>
        </pipeline>
      </compute-spec>
      """

      assert {:error, reason} = ComputeSpec.parse(xml)
      assert reason =~ "name"
    end

    test "parse rejects mutex violation: both module + ref attrs supplied" do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render">
            <function module="X" name="y" ref="../_renderer.ex"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      assert {:error, reason} = ComputeSpec.parse(xml)
      assert reason =~ "mutex" or reason =~ "both"
    end

    test "validate succeeds for M6 form when source-doc + function exist",
         %{store: store} do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render">
            <function ref="../_renderer.ex" name="render"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      {:ok, spec} = ComputeSpec.parse(xml)

      assert {:ok, validated_spec} =
               ComputeSpec.validate(spec, spec_path: "test/_compute", store: store)

      [render] = validated_spec.pipeline
      # M6 form's resolved module cached on the step after validate
      assert render.module != nil
      assert render.module == Cp.Test.M6Renderer
    end

    test "validate fails for M6 form when source-doc missing", %{store: store} do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render">
            <function ref="../missing.ex" name="render"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      {:ok, spec} = ComputeSpec.parse(xml)

      assert {:error, _reason} =
               ComputeSpec.validate(spec, spec_path: "test/_compute", store: store)
    end

    test "interpret runs M6-resolved render fn end-to-end", %{store: store} do
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="decode_json_array"/>
          <step kind="render">
            <function ref="../_renderer.ex" name="render"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      {:ok, spec} = ComputeSpec.parse(xml)
      {:ok, validated_spec} =
        ComputeSpec.validate(spec, spec_path: "test/_compute", store: store)

      raw_entries = [
        Jason.encode!(%{"id" => "t1", "title" => "alpha"}),
        Jason.encode!(%{"id" => "t2", "title" => "beta"})
      ]

      output = ComputeSpec.interpret(validated_spec, raw_entries, %{room_name: "general"})

      assert output =~ "general"
      assert output =~ "alpha"
      assert output =~ "beta"
    end

    test "M5 specs (existing <function module name>) stay backward-compatible after extension",
         %{store: store} do
      # Backward-compat anchor: existing M5 form still works post-(ii).
      xml = """
      <compute-spec schema="1">
        <pipeline>
          <step kind="render">
            <function module="Commonplace.Chat.ChatViewBuilder" name="build_view_xml"/>
          </step>
        </pipeline>
      </compute-spec>
      """

      {:ok, spec} = ComputeSpec.parse(xml)
      # validate/1 (M5 path) still works; validate/2 with empty opts also works
      assert {:ok, _spec} = ComputeSpec.validate(spec)
      assert {:ok, _spec} = ComputeSpec.validate(spec, store: store)
    end
  end
end
