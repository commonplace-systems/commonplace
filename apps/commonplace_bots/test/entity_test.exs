defmodule Commonplace.Bots.EntityTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Entity
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_entity_#{:rand.uniform(1_000_000_000)}")
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

  defp mint_bot_dir(opts) do
    persona = Keyword.get(opts, :persona, "You are alice.")
    trigger = Keyword.get(opts, :trigger, "(?i)@alice\\b")
    extras = Keyword.get(opts, :extras, %{})
    skip = Keyword.get(opts, :skip, [])

    schema =
      Schema.new_schema()
      |> maybe_add_file("persona.md", mint_text_doc("persona.md", persona), skip)
      |> maybe_add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""), skip)
      |> maybe_add_file("trigger.regex", mint_text_doc("trigger.regex", trigger), skip)

    schema =
      Enum.reduce(extras, schema, fn {name, body}, acc ->
        Schema.add_file(acc, name, mint_text_doc(name, body))
      end)

    mint_doc(schema)
  end

  defp maybe_add_file(schema, name, uuid, skip) do
    if name in skip, do: schema, else: Schema.add_file(schema, name, uuid)
  end

  defp mint_room_with_bots(bots) do
    schema = Schema.new_schema()

    schema =
      Enum.reduce(bots, schema, fn {name, dir_uuid}, acc ->
        Schema.add_directory(acc, name, dir_uuid)
      end)

    mint_doc(schema)
  end

  describe "load/3" do
    test "reads a well-formed bot directory" do
      uuid = mint_bot_dir(persona: "I am alice.", trigger: "(?i)@alice\\b")
      assert {:ok, entity} = Entity.load(CommitStoreClient, uuid, "alice.bot")
      assert entity.name == "alice"
      assert entity.dir_uuid == uuid
      assert entity.persona == "I am alice."
      assert entity.trigger_source == "(?i)@alice\\b"
      assert entity.trigger_kind == :regex
      assert is_binary(entity.memory_uuid)
      assert entity.bot_config == %{}
    end

    test "reads bot.json when present" do
      uuid =
        mint_bot_dir(
          extras: %{"bot.json" => ~s({"max_calls": 5})}
        )

      assert {:ok, entity} = Entity.load(CommitStoreClient, uuid, "bob.bot")
      assert entity.bot_config == %{"max_calls" => 5}
    end

    test "treats malformed bot.json as empty config" do
      uuid = mint_bot_dir(extras: %{"bot.json" => "{not json"})
      assert {:ok, entity} = Entity.load(CommitStoreClient, uuid, "carol.bot")
      assert entity.bot_config == %{}
    end

    test "rejects directories missing required children" do
      uuid = mint_bot_dir(skip: ["trigger.regex"])
      assert {:error, {:missing, "trigger.regex"}} =
               Entity.load(CommitStoreClient, uuid, "dora.bot")

      uuid = mint_bot_dir(skip: ["persona.md"])
      assert {:error, {:missing, "persona.md"}} =
               Entity.load(CommitStoreClient, uuid, "ed.bot")
    end

    # C3d: memory.jsonl is NO LONGER a required charter child (the desk moved
    # under the home). A charter-only dir (persona.md + trigger.regex) loads
    # fine and reports memory_uuid: nil.
    test "loads a charter-only dir without memory.jsonl (memory_uuid nil)" do
      uuid = mint_bot_dir(skip: ["memory.jsonl"])
      assert {:ok, entity} = Entity.load(CommitStoreClient, uuid, "fred.bot")
      assert entity.name == "fred"
      assert entity.memory_uuid == nil
    end

    test "strips the .bot suffix from the display name" do
      uuid = mint_bot_dir([])
      assert {:ok, entity} = Entity.load(CommitStoreClient, uuid, "alice.bot")
      assert entity.name == "alice"
      assert Entity.dir_entry_name(entity) == "alice.bot"
    end
  end

  describe "list_in_room/2" do
    test "enumerates only *.bot/ directory entries" do
      alice = mint_bot_dir(persona: "alice")
      bob = mint_bot_dir(persona: "bob")
      file_uuid = mint_text_doc("README.md", "hi")
      user_dir = mint_doc(Schema.new_schema())

      room_uuid =
        mint_room_with_bots([
          {"alice.bot", alice},
          {"bob.bot", bob},
          {"carol.usr", user_dir},
          {"readme.md", file_uuid}
        ])
      # Note: README.md was added as a directory entry above by the helper;
      # build via Schema directly to test the file vs dir filter.
      _ = room_uuid

      schema = Schema.new_schema()
      schema = Schema.add_directory(schema, "alice.bot", alice)
      schema = Schema.add_directory(schema, "bob.bot", bob)
      schema = Schema.add_directory(schema, "carol.usr", user_dir)
      schema = Schema.add_file(schema, "readme.md", file_uuid)
      room_uuid = mint_doc(schema)

      assert {:ok, bots} = Entity.list_in_room(CommitStoreClient, room_uuid)
      names = bots |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["alice.bot", "bob.bot"]

      assert Enum.find(bots, &(&1.name == "alice.bot")).dir_uuid == alice
      assert Enum.find(bots, &(&1.name == "bob.bot")).dir_uuid == bob
    end

    test "returns empty list when no bots present" do
      schema = Schema.new_schema()
      room_uuid = mint_doc(schema)
      assert {:ok, []} = Entity.list_in_room(CommitStoreClient, room_uuid)
    end
  end
end
