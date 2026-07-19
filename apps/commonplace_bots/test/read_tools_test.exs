defmodule Commonplace.Bots.Worker.ReadToolsTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Entity
  alias Commonplace.Bots.Worker.Tools.{
    CheckTurnRemaining,
    ListFiles,
    ReadChat,
    ReadFile,
    ReadMemory
  }

  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_readtools_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_doc(doc) do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_text_doc(name, body) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    mint_doc(doc)
  end

  defp mint_bot_dir(memory_body \\ "") do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "I am alice."))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", memory_body))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", "(?i)@alice"))

    mint_doc(schema)
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp post(room, uuid, text, author) do
    Actions.post_message(uuid, text, room: room, signer_id: "sig", author_path: author)
  end

  defp load_entity(uuid), do: elem(Entity.load(CommitStoreClient, uuid, "alice.bot"), 1)

  defp state(entity, opts) do
    %{
      entity: entity,
      event: %{"message_id" => "m1"},
      room: "demo",
      opts: opts
    }
  end

  describe "read_chat" do
    test "returns recent messages as rendered entries" do
      messages_uuid = mint_messages_doc()
      {:ok, _} = post("demo", messages_uuid, "hello", "human.usr")
      {:ok, _} = post("demo", messages_uuid, "world", "alice.bot")

      entity = load_entity(mint_bot_dir())

      {:ok, json} = ReadChat.call(state(entity, messages_uuid: messages_uuid), %{})
      decoded = Jason.decode!(json)

      assert length(decoded) == 2
      assert Enum.map(decoded, & &1["text"]) == ["hello", "world"]
      assert Enum.map(decoded, & &1["author"]) == ["human.usr", "alice.bot"]

      assert Enum.all?(decoded, fn e -> is_binary(e["msg_id"]) and is_binary(e["ts"]) end)
    end

    test "respects the limit arg" do
      messages_uuid = mint_messages_doc()
      for i <- 1..5, do: post("demo", messages_uuid, "msg-#{i}", "human.usr")

      entity = load_entity(mint_bot_dir())

      {:ok, json} =
        ReadChat.call(state(entity, messages_uuid: messages_uuid), %{"limit" => 2})

      decoded = Jason.decode!(json)
      assert length(decoded) == 2
      assert Enum.map(decoded, & &1["text"]) == ["msg-4", "msg-5"]
    end

    test "before arg returns messages preceding a given id" do
      messages_uuid = mint_messages_doc()
      {:ok, %{message_id: id1}} = post("demo", messages_uuid, "first", "human.usr")
      {:ok, %{message_id: id2}} = post("demo", messages_uuid, "second", "human.usr")
      {:ok, _} = post("demo", messages_uuid, "third", "human.usr")

      entity = load_entity(mint_bot_dir())

      {:ok, json} =
        ReadChat.call(state(entity, messages_uuid: messages_uuid), %{"before" => id2})

      decoded = Jason.decode!(json)
      assert length(decoded) == 1
      assert hd(decoded)["msg_id"] == id1
    end
  end

  describe "read_memory" do
    # C3d: memory moved UNDER the bot's home (a zoned note-meta). The home-
    # anchored read/append + enforce behavior is covered in MudToolsTest against
    # a provisioned citizen. Here we only pin the graceful no-mud_ctx path: a
    # tool state carrying no `mud_ctx` (unprovisioned bot / not in the world)
    # reads an empty log rather than crashing.
    test "returns an empty log gracefully when the bot has no mud_ctx" do
      entity = load_entity(mint_bot_dir())
      {:ok, json} = ReadMemory.call(state(entity, []), %{})
      assert Jason.decode!(json) == []
    end
  end

  describe "list_files" do
    test "returns the bot's own children, sorted" do
      entity = load_entity(mint_bot_dir())
      {:ok, json} = ListFiles.call(state(entity, []), %{})
      decoded = Jason.decode!(json)
      names = Enum.map(decoded, & &1["name"])
      assert names == Enum.sort(["persona.md", "memory.jsonl", "trigger.regex"])
    end

    test "rejects non-root paths" do
      entity = load_entity(mint_bot_dir())
      assert {:error, _} = ListFiles.call(state(entity, []), %{"path" => "/sub"})
      assert {:error, _} = ListFiles.call(state(entity, []), %{"path" => ".."})
    end
  end

  describe "read_file" do
    test "reads a valid name" do
      entity = load_entity(mint_bot_dir())
      assert {:ok, "I am alice."} = ReadFile.call(state(entity, []), %{"name" => "persona.md"})
    end

    test "rejects path-traversal-shaped names" do
      entity = load_entity(mint_bot_dir())
      assert {:error, _} = ReadFile.call(state(entity, []), %{"name" => "../etc/passwd"})
      assert {:error, _} = ReadFile.call(state(entity, []), %{"name" => "sub/file"})
      assert {:error, _} = ReadFile.call(state(entity, []), %{"name" => ""})
    end

    test "errors on missing file" do
      entity = load_entity(mint_bot_dir())
      assert {:error, "read_file: no such file"} =
               ReadFile.call(state(entity, []), %{"name" => "ghost.md"})
    end
  end

  describe "check_turn_remaining" do
    test "returns budget snapshot when set" do
      entity = load_entity(mint_bot_dir())

      base = state(entity, [])

      base_with_snap =
        Map.put(base, :budget_snapshot, %{
          calls_remaining: 7,
          output_tokens_remaining: 3000,
          wall_ms_remaining: 42_000
        })

      {:ok, json} = CheckTurnRemaining.call(base_with_snap, %{})
      decoded = Jason.decode!(json)
      assert decoded["calls_remaining"] == 7
      assert decoded["output_tokens_remaining"] == 3000
      assert decoded["wall_ms_remaining"] == 42_000
    end

    test "returns 'unknown' when no snapshot present" do
      entity = load_entity(mint_bot_dir())
      {:ok, json} = CheckTurnRemaining.call(state(entity, []), %{})
      assert Jason.decode!(json) == %{"status" => "unknown"}
    end
  end
end
