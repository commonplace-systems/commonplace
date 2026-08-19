defmodule Commonplace.MCP.CrdtToolsTest do
  @moduledoc """
  CX-y3q: CRDT-defined dynamic MCP tools. Tests the runtime catalog
  reader (`list/2`), the magenta-orchestrating dispatcher (`call/3`),
  template rendering, and the error paths called out in the doc
  (`docs/dynamic-mcp-tools.md`).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Document.ContentType
  alias Commonplace.MCP.CrdtTools
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.{Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "crdt_tools_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"crdt_tools_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = "crdt-tools-root-#{:rand.uniform(1_000_000)}"
    root_schema = Schema.new_schema()
    CommitStore.create_commit(name, root_uuid, Encoding.encode_update(root_schema), nil)

    %{store: name, root: root_uuid}
  end

  defp seed_interface(store, root_uuid, name, magenta_block) do
    interface = %{
      "name" => name,
      "description" => "Test tool: #{name}",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "magenta" => magenta_block
    }

    json = Jason.encode!(interface)

    # Create the interface leaf doc
    interface_uuid = UUID.uuid4()
    doc = Doc.new()
    doc = ContentType.create(doc, :text, "#{name}.json")
    doc = ContentType.insert_text(doc, 0, json)
    {:ok, _} = CommitStore.ensure_genesis(store, interface_uuid)
    CommitStore.create_chained_commit(store, interface_uuid, Encoding.encode_update(doc))

    # Build/update __system → tools → <name> in root schema
    root = load_schema(store, root_uuid)

    {root, system_uuid} =
      case Schema.get_entry(root, "__system") do
        {:ok, %{node_id: u}} ->
          {root, u}

        :error ->
          system_uuid = UUID.uuid4()
          system_schema = Schema.new_schema()
          {:ok, _} = CommitStore.ensure_genesis(store, system_uuid)

          CommitStore.create_chained_commit(
            store,
            system_uuid,
            Encoding.encode_update(system_schema)
          )

          {Schema.add_directory(root, "__system", system_uuid), system_uuid}
      end

    {system, tools_uuid} =
      case Schema.get_entry(load_schema(store, system_uuid), "tools") do
        {:ok, %{node_id: u}} ->
          {load_schema(store, system_uuid), u}

        :error ->
          tools_uuid = UUID.uuid4()
          tools_schema = Schema.new_schema()
          {:ok, _} = CommitStore.ensure_genesis(store, tools_uuid)

          CommitStore.create_chained_commit(
            store,
            tools_uuid,
            Encoding.encode_update(tools_schema)
          )

          system = load_schema(store, system_uuid)
          {Schema.add_directory(system, "tools", tools_uuid), tools_uuid}
      end

    # Update system to include tools entry
    CommitStore.create_chained_commit(store, system_uuid, Encoding.encode_update(system))

    # Add tool entry under tools
    tools_doc = load_schema(store, tools_uuid)
    tools_doc = Schema.add_file(tools_doc, name, interface_uuid)
    CommitStore.create_chained_commit(store, tools_uuid, Encoding.encode_update(tools_doc))

    # Update root to include __system entry (idempotent — only commits if new)
    CommitStore.create_chained_commit(store, root_uuid, Encoding.encode_update(root))

    interface_uuid
  end

  defp seed_handler_doc(store, root_uuid, target_path) do
    # Just create a doc at target_path so Walk.resolve_path succeeds.
    ["__system", "handlers", handler_name] = String.split(target_path, "/")

    handler_uuid = UUID.uuid4()
    handler_doc = Doc.new()
    {:ok, _} = CommitStore.ensure_genesis(store, handler_uuid)
    CommitStore.create_chained_commit(store, handler_uuid, Encoding.encode_update(handler_doc))

    # Ensure __system/handlers/<handler_name> is registered
    root = load_schema(store, root_uuid)

    {root, system_uuid} =
      case Schema.get_entry(root, "__system") do
        {:ok, %{node_id: u}} ->
          {root, u}

        :error ->
          su = UUID.uuid4()
          ss = Schema.new_schema()
          {:ok, _} = CommitStore.ensure_genesis(store, su)
          CommitStore.create_chained_commit(store, su, Encoding.encode_update(ss))
          {Schema.add_directory(root, "__system", su), su}
      end

    {system, handlers_uuid} =
      case Schema.get_entry(load_schema(store, system_uuid), "handlers") do
        {:ok, %{node_id: u}} ->
          {load_schema(store, system_uuid), u}

        :error ->
          hu = UUID.uuid4()
          hs = Schema.new_schema()
          {:ok, _} = CommitStore.ensure_genesis(store, hu)
          CommitStore.create_chained_commit(store, hu, Encoding.encode_update(hs))
          system = load_schema(store, system_uuid)
          {Schema.add_directory(system, "handlers", hu), hu}
      end

    CommitStore.create_chained_commit(store, system_uuid, Encoding.encode_update(system))
    CommitStore.create_chained_commit(store, root_uuid, Encoding.encode_update(root))

    handlers_doc = load_schema(store, handlers_uuid)
    handlers_doc = Schema.add_file(handlers_doc, handler_name, handler_uuid)
    CommitStore.create_chained_commit(store, handlers_uuid, Encoding.encode_update(handlers_doc))

    handler_uuid
  end

  defp load_schema(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  describe "list/2" do
    test "returns [] when __system/tools doesn't exist", %{store: store, root: root} do
      assert [] == CrdtTools.list(store, root)
    end

    test "returns descriptors for each interface doc under __system/tools/",
         %{store: store, root: root} do
      seed_interface(store, root, "alpha", base_magenta("a"))
      seed_interface(store, root, "beta", base_magenta("b"))

      tools = CrdtTools.list(store, root)
      names = Enum.map(tools, & &1["name"])

      assert "alpha" in names
      assert "beta" in names

      for tool <- tools do
        assert is_binary(tool["description"])
        assert is_map(tool["inputSchema"])
      end
    end

    test "skips interface docs whose JSON is unparseable",
         %{store: store, root: root} do
      seed_interface(store, root, "good", base_magenta("g"))

      # Seed a malformed entry directly
      bad_uuid = UUID.uuid4()

      bad_doc =
        Doc.new()
        |> ContentType.create(:text, "bad.json")
        |> ContentType.insert_text(0, "not json {[")

      {:ok, _} = CommitStore.ensure_genesis(store, bad_uuid)
      CommitStore.create_chained_commit(store, bad_uuid, Encoding.encode_update(bad_doc))

      root_doc = load_schema(store, root)
      {:ok, system_entry} = Schema.get_entry(root_doc, "__system")
      system_doc = load_schema(store, system_entry.node_id)
      {:ok, tools_entry} = Schema.get_entry(system_doc, "tools")
      tools_doc = load_schema(store, tools_entry.node_id)
      tools_doc = Schema.add_file(tools_doc, "bad", bad_uuid)

      CommitStore.create_chained_commit(
        store,
        tools_entry.node_id,
        Encoding.encode_update(tools_doc)
      )

      tools = CrdtTools.list(store, root)
      names = Enum.map(tools, & &1["name"])

      assert "good" in names
      refute "bad" in names
    end
  end

  describe "call/3 — happy path" do
    test "publishes magenta on the dispatch topic + returns the success reply",
         %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/echo")

      seed_interface(store, root, "echo", %{
        "target_path" => "__system/handlers/echo",
        "send_type" => "echo",
        "send_payload_template" => %{"text" => "{{text}}"},
        "reply" => %{
          "success_type" => "echoed",
          "error_type" => "echo_failed",
          "timeout_ms" => 1_000
        }
      })

      topic = "commands/__system/handlers/echo/echo"

      # Subscribe BEFORE call so we see the request and can reply.
      Magenta.subscribe(topic)

      task =
        Task.async(fn ->
          CrdtTools.call("echo", %{"text" => "hello"}, store: store, root_uuid: root)
        end)

      # Receive the dispatcher's outbound request, extract correlation_id, reply.
      assert_receive {:magenta, ^topic,
                      %Magenta{
                        type: "echo",
                        payload: %{"text" => "hello", "correlation_id" => cid}
                      }},
                     1_000

      Magenta.send(
        topic,
        Magenta.message("echoed", "test_handler", %{
          "correlation_id" => cid,
          "result" => "hello-back"
        })
      )

      assert {:ok, result} = Task.await(task, 2_000)
      assert result["structuredContent"]["result"] == "hello-back"
      refute result["isError"]
    end

    test "error reply maps to in-band MCP tool error", %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/fails")

      seed_interface(store, root, "fails", %{
        "target_path" => "__system/handlers/fails",
        "send_type" => "fail",
        "send_payload_template" => %{},
        "reply" => %{
          "success_type" => "ok",
          "error_type" => "failed",
          "timeout_ms" => 1_000
        }
      })

      topic = "commands/__system/handlers/fails/fail"
      Magenta.subscribe(topic)

      task =
        Task.async(fn ->
          CrdtTools.call("fails", %{}, store: store, root_uuid: root)
        end)

      assert_receive {:magenta, ^topic,
                      %Magenta{type: "fail", payload: %{"correlation_id" => cid}}},
                     1_000

      Magenta.send(
        topic,
        Magenta.message("failed", "h", %{"correlation_id" => cid, "message" => "kaboom"})
      )

      assert {:ok, result} = Task.await(task, 2_000)
      assert result["isError"] == true
      [content | _] = result["content"]
      assert content["text"] =~ "kaboom"
    end
  end

  describe "call/3 — error paths" do
    test "unknown tool returns :not_found", %{store: store, root: root} do
      assert {:error, :not_found} = CrdtTools.call("nope", %{}, store: store, root_uuid: root)
    end

    test "interface present but handler doc path doesn't resolve",
         %{store: store, root: root} do
      seed_interface(store, root, "orphan", %{
        "target_path" => "__system/handlers/missing",
        "send_type" => "x",
        "send_payload_template" => %{},
        "reply" => %{"success_type" => "ok", "error_type" => "ko", "timeout_ms" => 1_000}
      })

      assert {:error, {:handler_not_found, "__system/handlers/missing"}} =
               CrdtTools.call("orphan", %{}, store: store, root_uuid: root)
    end

    test "no reply within timeout → in-band tool error", %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/silent")

      seed_interface(store, root, "silent", %{
        "target_path" => "__system/handlers/silent",
        "send_type" => "ping",
        "send_payload_template" => %{},
        "reply" => %{"success_type" => "pong", "error_type" => "boom", "timeout_ms" => 100}
      })

      assert {:ok, result} = CrdtTools.call("silent", %{}, store: store, root_uuid: root)
      assert result["isError"] == true
      [%{"text" => text} | _] = result["content"]
      assert text =~ "timed out"
      assert text =~ "silent"
    end

    test "missing template variable → in-band tool error", %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/strict")

      seed_interface(store, root, "strict", %{
        "target_path" => "__system/handlers/strict",
        "send_type" => "go",
        "send_payload_template" => %{"required_field" => "{{missing}}"},
        "reply" => %{"success_type" => "done", "error_type" => "fail", "timeout_ms" => 1_000}
      })

      assert {:ok, result} =
               CrdtTools.call("strict", %{"present" => "x"}, store: store, root_uuid: root)

      assert result["isError"] == true
      [%{"text" => text} | _] = result["content"]
      assert text =~ "missing"
    end
  end

  describe "template rendering" do
    test "full-value substitution preserves typed JSON values", %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/typed")

      seed_interface(store, root, "typed", %{
        "target_path" => "__system/handlers/typed",
        "send_type" => "send",
        "send_payload_template" => %{
          "n" => "{{n}}",
          "flag" => "{{flag}}",
          "nested" => "{{nested}}"
        },
        "reply" => %{"success_type" => "ok", "error_type" => "ko", "timeout_ms" => 1_000}
      })

      topic = "commands/__system/handlers/typed/send"
      Magenta.subscribe(topic)

      task =
        Task.async(fn ->
          CrdtTools.call(
            "typed",
            %{"n" => 42, "flag" => true, "nested" => %{"x" => [1, 2]}},
            store: store,
            root_uuid: root
          )
        end)

      assert_receive {:magenta, ^topic, %Magenta{payload: payload}}, 1_000
      assert payload["n"] == 42
      assert payload["flag"] == true
      assert payload["nested"] == %{"x" => [1, 2]}

      Magenta.send(
        topic,
        Magenta.message("ok", "h", %{"correlation_id" => payload["correlation_id"]})
      )

      Task.await(task, 2_000)
    end

    test "string interpolation when template value is not exactly {{var}}",
         %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/interp")

      seed_interface(store, root, "interp", %{
        "target_path" => "__system/handlers/interp",
        "send_type" => "send",
        "send_payload_template" => %{"label" => "branch-{{name}}"},
        "reply" => %{"success_type" => "ok", "error_type" => "ko", "timeout_ms" => 1_000}
      })

      topic = "commands/__system/handlers/interp/send"
      Magenta.subscribe(topic)

      task =
        Task.async(fn ->
          CrdtTools.call("interp", %{"name" => "feature-x"}, store: store, root_uuid: root)
        end)

      assert_receive {:magenta, ^topic, %Magenta{payload: payload}}, 1_000
      assert payload["label"] == "branch-feature-x"

      Magenta.send(
        topic,
        Magenta.message("ok", "h", %{"correlation_id" => payload["correlation_id"]})
      )

      Task.await(task, 2_000)
    end
  end

  describe "correlation_id" do
    test "is server-injected even if template tries to set one",
         %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/forge")

      seed_interface(store, root, "forge", %{
        "target_path" => "__system/handlers/forge",
        "send_type" => "go",
        "send_payload_template" => %{"correlation_id" => "{{forged}}"},
        "reply" => %{"success_type" => "ok", "error_type" => "ko", "timeout_ms" => 1_000}
      })

      topic = "commands/__system/handlers/forge/go"
      Magenta.subscribe(topic)

      task =
        Task.async(fn ->
          CrdtTools.call("forge", %{"forged" => "EVIL_ID"}, store: store, root_uuid: root)
        end)

      assert_receive {:magenta, ^topic, %Magenta{payload: payload}}, 1_000
      refute payload["correlation_id"] == "EVIL_ID"
      assert is_binary(payload["correlation_id"])

      Magenta.send(
        topic,
        Magenta.message("ok", "h", %{"correlation_id" => payload["correlation_id"]})
      )

      Task.await(task, 2_000)
    end

    test "replies with mismatched correlation_id are ignored",
         %{store: store, root: root} do
      seed_handler_doc(store, root, "__system/handlers/strict_cid")

      seed_interface(store, root, "strict_cid", %{
        "target_path" => "__system/handlers/strict_cid",
        "send_type" => "go",
        "send_payload_template" => %{},
        "reply" => %{"success_type" => "ok", "error_type" => "ko", "timeout_ms" => 300}
      })

      topic = "commands/__system/handlers/strict_cid/go"
      Magenta.subscribe(topic)

      task =
        Task.async(fn ->
          CrdtTools.call("strict_cid", %{}, store: store, root_uuid: root)
        end)

      assert_receive {:magenta, ^topic, %Magenta{payload: %{"correlation_id" => cid}}}, 1_000

      # Send a reply with a DIFFERENT cid — dispatcher should ignore + time out.
      Magenta.send(topic, Magenta.message("ok", "h", %{"correlation_id" => "other-cid"}))

      assert {:ok, result} = Task.await(task, 2_000)
      assert result["isError"] == true
      [%{"text" => text} | _] = result["content"]
      assert text =~ "timed out"
      _ = cid
    end
  end

  defp base_magenta(suffix) do
    %{
      "target_path" => "__system/handlers/#{suffix}",
      "send_type" => "go",
      "send_payload_template" => %{},
      "reply" => %{"success_type" => "ok", "error_type" => "ko", "timeout_ms" => 1_000}
    }
  end
end
