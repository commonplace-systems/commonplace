defmodule Commonplace.MUD.SchemasTest do
  use ExUnit.Case

  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.{Object, Player, Room}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_schemas_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  describe "encode/decode" do
    test "room round-trip" do
      r = %Room{
        name: "Start",
        description: "A cozy chamber.",
        exits: %{"north" => "../forest"},
        tick_interval_ms: nil
      }

      {:ok, decoded} = r |> Schemas.encode_room() |> Schemas.decode_room()
      assert decoded == r
    end

    test "object round-trip with aliases" do
      o = %Object{
        name: "cloak",
        aliases: ["cape", "black cloak"],
        description: "Heavy and warm.",
        fixed: false,
        tick_interval_ms: nil
      }

      {:ok, decoded} = o |> Schemas.encode_object() |> Schemas.decode_object()
      assert decoded == o
    end

    test "player round-trip" do
      p = %Player{name: "alice", title: "Alice the Curious", description: "In a tunic."}
      {:ok, decoded} = p |> Schemas.encode_player() |> Schemas.decode_player()
      assert decoded == p
    end

    test "decoder fills missing keys with defaults" do
      json = ~s({"kind":"room","name":"x"})

      {:ok, %Room{name: "x", description: "", exits: %{}, tick_interval_ms: nil}} =
        Schemas.decode_room(json)
    end
  end

  describe "load from store" do
    test "create_dir_with_meta + load_room round-trip", %{store: store} do
      json = Schemas.encode_room(%Room{name: "Start", description: "A room.", exits: %{}})
      {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)

      {:ok, %Room{name: "Start", description: "A room."}} = Schemas.load_room(dir_uuid, store)
    end

    test "load_object", %{store: store} do
      json =
        Schemas.encode_object(%Object{name: "cloak", description: "Warm.", aliases: ["cape"]})

      {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.object_filename(), json, store)

      {:ok, obj} = Schemas.load_object(dir_uuid, store)
      assert obj.name == "cloak"
      assert obj.aliases == ["cape"]
    end

    test "missing meta entry returns error", %{store: store} do
      {:ok, empty_dir} = Schemas.create_dir_with_meta(nil, nil, store)
      assert {:error, _} = Schemas.load_room(empty_dir, store)
    end

    test "write_meta_doc replaces content", %{store: store} do
      json = Schemas.encode_room(%Room{name: "Start", description: "First."})
      {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)

      {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
      {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())

      new_json = Schemas.encode_room(%Room{name: "Start", description: "Second."})
      :ok = Schemas.write_meta_doc(entry.node_id, new_json, store)

      {:ok, %Room{description: "Second."}} = Schemas.load_room(dir_uuid, store)
    end
  end

  describe "writer identity — stable per-doc hand (CX-41qg.3)" do
    defp sv_client_ids(doc) do
      Yelixer.BlockStore.state_vector(doc.store).clocks
      |> Map.keys()
      |> MapSet.new()
    end

    test "repeated write_meta_doc calls keep the meta doc's client-id set bounded",
         %{store: store} do
      json = Schemas.encode_room(%Room{name: "Start", description: "v0"})
      {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)
      {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
      {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())

      Enum.each(1..15, fn n ->
        new_json = Schemas.encode_room(%Room{name: "Start", description: "v#{n}"})
        :ok = Schemas.write_meta_doc(entry.node_id, new_json, store)
      end)

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, entry.node_id)
      client_ids = sv_client_ids(doc)

      assert MapSet.size(client_ids) <= 2,
             "expected a bounded (<=2) set of client ids after 15 writes, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)}"
    end

    test "repeated add-file-style directory schema commits keep the dir's client-id set bounded",
         %{store: store} do
      {:ok, empty_dir} = Schemas.create_dir_with_meta(nil, nil, store)

      Enum.each(1..15, fn n ->
        {:ok, schema} = Schemas.load_dir_schema(empty_dir, store)
        schema = Schema.add_file(schema, "file#{n}.txt", UUID.uuid4())
        update = Yelixer.Encoding.encode_update(schema)
        Commonplace.Store.CommitStoreClient.create_chained_commit(store, empty_dir, update)
      end)

      {:ok, schema} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, empty_dir)
      client_ids = sv_client_ids(schema)

      assert MapSet.size(client_ids) <= 2,
             "expected a bounded (<=2) set of client ids after 15 directory writes, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)}"
    end
  end
end
