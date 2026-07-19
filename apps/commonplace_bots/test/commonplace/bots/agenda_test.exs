defmodule Commonplace.Bots.AgendaTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Agenda, Entity}
  alias Commonplace.Bots.Worker.Tools.UpdateAgenda
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_agenda_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_doc(doc) do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_text_doc(name, body) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    mint_doc(doc)
  end

  defp mint_bot_dir do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc("persona.md", "I am alice."))
      |> Schema.add_file("memory.jsonl", mint_text_doc("memory.jsonl", ""))
      |> Schema.add_file("trigger.regex", mint_text_doc("trigger.regex", "(?i)@alice\\b"))

    mint_doc(schema)
  end

  defp fresh_sc do
    {pub, priv} = Signing.generate_keypair()
    %SigningContext{identity_uuid: UUID.uuid4(), private_key: priv, public_key: pub}
  end

  test "ensure/read/append round-trip; ensure is idempotent" do
    dir_uuid = mint_bot_dir()
    {:ok, entity} = Entity.load(CommitStoreClient, dir_uuid, "alice.bot")
    sc = fresh_sc()

    # No agenda doc yet.
    assert Agenda.read(entity, CommitStoreClient) == []

    {:ok, uuid} = Agenda.ensure(entity, CommitStoreClient, signing_context: sc)
    assert is_binary(uuid)

    # Idempotent — same uuid on re-ensure.
    {:ok, uuid2} = Agenda.ensure(entity, CommitStoreClient, signing_context: sc)
    assert uuid2 == uuid

    :ok = Agenda.append(entity, %{"text" => "consolidate the pins"}, CommitStoreClient,
            signing_context: sc)

    :ok = Agenda.append(entity, %{"text" => "file the association"}, CommitStoreClient,
            signing_context: sc)

    items = Agenda.read(entity, CommitStoreClient)
    assert length(items) == 2
    assert Enum.map(items, & &1["text"]) == ["consolidate the pins", "file the association"]
    # ts stamped when the caller omits it.
    assert Enum.all?(items, fn i -> is_binary(i["ts"]) end)
  end

  test "appends are bot-signed (latest commit signed by the bot's key)" do
    dir_uuid = mint_bot_dir()
    {:ok, entity} = Entity.load(CommitStoreClient, dir_uuid, "alice.bot")
    sc = fresh_sc()

    {:ok, uuid} = Agenda.ensure(entity, CommitStoreClient, signing_context: sc)
    :ok = Agenda.append(entity, %{"text" => "signed item"}, CommitStoreClient, signing_context: sc)

    {:ok, head} = CommitStore.latest_commit(CommitStore, uuid)
    assert Signing.signed?(head)
    assert head.signer_id == Signing.signer_id(sc.identity_uuid, sc.public_key)
  end

  test "the update_agenda tool appends an item" do
    dir_uuid = mint_bot_dir()
    {:ok, entity} = Entity.load(CommitStoreClient, dir_uuid, "alice.bot")
    sc = fresh_sc()

    state = %{
      entity: entity,
      opts: [store: CommitStoreClient],
      signing_context: sc
    }

    assert {:ok, _} = UpdateAgenda.call(state, %{"text" => "from the tool"})

    items = Agenda.read(entity, CommitStoreClient)
    assert Enum.map(items, & &1["text"]) == ["from the tool"]
  end

  test "update_agenda rejects an empty text field" do
    dir_uuid = mint_bot_dir()
    {:ok, entity} = Entity.load(CommitStoreClient, dir_uuid, "alice.bot")

    state = %{entity: entity, opts: [store: CommitStoreClient], signing_context: nil}

    assert {:error, _} = UpdateAgenda.call(state, %{"text" => ""})
    assert {:error, _} = UpdateAgenda.call(state, %{})
  end
end
