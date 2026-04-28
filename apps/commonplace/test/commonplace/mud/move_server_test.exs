defmodule Commonplace.MUD.MoveServerTest do
  use ExUnit.Case

  alias Commonplace.MUD.{MoveServer, Schemas}
  alias Commonplace.MUD.Schemas.Object
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_move_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    server_name = :"move_server_#{:rand.uniform(1_000_000)}"
    {:ok, _} = MoveServer.start_link(name: server_name, store: store_name)

    %{store: store_name, server: server_name}
  end

  defp make_dir_with_object(store, obj_name) do
    obj_json = Schemas.encode_object(%Object{name: obj_name, description: "An object."})
    obj_dir = Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, store)

    parent = UUID.uuid4()
    schema = Schema.new_schema() |> Schema.add_directory("#{obj_name}.obj", obj_dir)
    update = Encoding.encode_update(schema)
    CommitStore.create_commit(store, parent, update, nil)

    {parent, obj_dir}
  end

  defp empty_dir(store) do
    uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp load(uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(uuid, store)
    schema
  end

  test "successful move adds to dest and removes from source", %{store: store, server: server} do
    {source, obj_dir} = make_dir_with_object(store, "cloak")
    dest = empty_dir(store)

    :ok = MoveServer.move(obj_dir, "cloak.obj", source, dest, server)

    assert :error = Schema.get_entry(load(source, store), "cloak.obj")
    {:ok, entry} = Schema.get_entry(load(dest, store), "cloak.obj")
    assert entry.node_id == obj_dir
    assert entry.type == :dir
  end

  test "race-loser gets :gone", %{store: store, server: server} do
    {source, obj_dir} = make_dir_with_object(store, "sword")
    dest_a = empty_dir(store)
    dest_b = empty_dir(store)

    :ok = MoveServer.move(obj_dir, "sword.obj", source, dest_a, server)
    {:error, :gone} = MoveServer.move(obj_dir, "sword.obj", source, dest_b, server)
  end

  test "moving to same dir is a no-op", %{store: store, server: server} do
    {source, obj_dir} = make_dir_with_object(store, "torch")
    :ok = MoveServer.move(obj_dir, "torch.obj", source, source, server)
    {:ok, entry} = Schema.get_entry(load(source, store), "torch.obj")
    assert entry.node_id == obj_dir
  end

  test "missing entry at source returns :gone", %{store: store, server: server} do
    source = empty_dir(store)
    dest = empty_dir(store)
    {:error, :gone} = MoveServer.move(UUID.uuid4(), "ghost.obj", source, dest, server)
  end

  test "name collision at dest returns :collision", %{store: store, server: server} do
    {source, obj_dir} = make_dir_with_object(store, "cloak")
    {dest, _other} = make_dir_with_object(store, "cloak")
    {:error, :collision} = MoveServer.move(obj_dir, "cloak.obj", source, dest, server)
  end
end
