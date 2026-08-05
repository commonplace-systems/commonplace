defmodule Commonplace.MUD.WorldMergeMetaCasTest do
  @moduledoc """
  CX-r97r — `World.merge_meta/5`'s strict-CAS read-modify-write loop.

  Setup mirrors `Commonplace.MUD.SchemasTest`: an isolated named
  `CommitStore` instance per test, no shared/global store.

  These are deterministic, mechanical tests (no concurrency) — the
  "conflict" case is simulated by calling `Schemas.write_meta_doc/4`
  directly with a deliberately stale `:expect_parent`, rather than by
  racing two processes.
  """
  use ExUnit.Case

  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.MUD.World
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_merge_meta_cas_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  test "(1) normal merge_meta still works end-to-end", %{store: store} do
    json = Schemas.encode_room(%Room{name: "Start", description: "A room."})
    {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)

    assert :ok = World.merge_meta(dir_uuid, Schemas.room_filename(), %{"description" => "Second."}, store)

    {:ok, %Room{description: "Second."}} = Schemas.load_room(dir_uuid, store)
  end

  test "(2) setting a field to nil still deletes it", %{store: store} do
    json = Schemas.encode_room(%Room{name: "Start", description: "A room."})
    {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)

    assert :ok =
             World.merge_meta(dir_uuid, Schemas.room_filename(), %{"tick_message" => "hi"}, store)

    {:ok, with_msg} = World.get_meta_map(dir_uuid, Schemas.room_filename(), store)
    assert with_msg["tick_message"] == "hi"

    assert :ok =
             World.merge_meta(dir_uuid, Schemas.room_filename(), %{"tick_message" => nil}, store)

    {:ok, without_msg} = World.get_meta_map(dir_uuid, Schemas.room_filename(), store)
    refute Map.has_key?(without_msg, "tick_message")
  end

  test "(3) latest_commit_id/2 returns nil for no commits, a binary id after a write", %{
    store: store
  } do
    json = Schemas.encode_room(%Room{name: "Start", description: "A room."})
    {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)

    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())

    assert is_binary(Schemas.latest_commit_id(entry.node_id, store))
    assert Schemas.latest_commit_id(UUID.uuid4(), store) == nil
  end

  test "(4) a stale :expect_parent loses the CAS -> {:error, :parent_moved}, doc unchanged", %{
    store: store
  } do
    json = Schemas.encode_room(%Room{name: "Start", description: "First."})
    {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)

    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())

    stale_parent = Schemas.latest_commit_id(entry.node_id, store)

    # The doc moves out from under the stale token via an ordinary merge_meta.
    assert :ok =
             World.merge_meta(dir_uuid, Schemas.room_filename(), %{"description" => "Second."}, store)

    {:ok, %Room{description: "Second."}} = Schemas.load_room(dir_uuid, store)

    # A write built against the now-stale parent loses the CAS.
    losing_json = Schemas.encode_room(%Room{name: "Start", description: "Should not land."})

    assert {:error, :parent_moved} =
             Schemas.write_meta_doc(entry.node_id, losing_json, store, expect_parent: stale_parent)

    # The doc content is unchanged by the losing write.
    {:ok, %Room{description: "Second."}} = Schemas.load_room(dir_uuid, store)
  end
end
