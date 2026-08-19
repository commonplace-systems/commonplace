defmodule Commonplace.MUD.WorldCorruptMetaRecoveryTest do
  @moduledoc """
  CX-t3bt / CX-r97r — what does the system DO with an already-corrupt
  meta doc?

  CX-r97r stopped concurrent appends from CREATING corruption. It says
  nothing about a doc that is already corrupt, and two open questions
  hung on that, both recorded as INFERENCE FROM THE MECHANISM and
  explicitly not tested:

    1. Can a later write REPAIR a corrupt doc? A subsequent
       minimal-diff replace could overwrite the corrupt span and
       restore valid JSON. If so, a corrupt doc could silently become
       readable again — which is a candidate explanation for CX-t3bt's
       "an entry appeared later with no intervening write", and is
       ALSO how a real corruption incident could erase its own
       evidence before anyone looks.

    2. What happens to a WRITE aimed at a corrupt doc? `merge_meta`
       reads and `Jason.decode`s before merging, so a corrupt body has
       to go somewhere. Silently overwriting it would destroy whatever
       survived; failing loudly preserves it.

  These are answered here by construction rather than by argument. The
  corruption is INJECTED deliberately (`write_meta_doc` replaces text
  and verifies the roundtrip — it never asserts the payload is valid
  JSON), so this exercises the real read/write path against a real
  corrupt body.
  """
  use ExUnit.Case

  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.MUD.World
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}

  # The exact shape CX-r97r observed in the wild: one stray brace
  # spliced mid-structure, only ONE "entries" key, so it is a hybrid
  # rather than two concatenated documents.
  @spliced ~s({"entries":[{"marker":"a"}}],"zone":"z-1"})

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_corrupt_meta_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  defp meta_node_id(dir_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
    entry.node_id
  end

  defp raw_content(dir_uuid, store) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, meta_node_id(dir_uuid, store))
    ContentType.get_content(doc)
  end

  # Build a real dir with a real meta, then inject a corrupt body
  # through the REAL write path.
  defp corrupt_dir(store) do
    json = Schemas.encode_room(%Room{name: "Start", description: "A room."})
    {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)
    :ok = Schemas.write_meta_doc(meta_node_id(dir_uuid, store), @spliced, store)
    dir_uuid
  end

  test "the injected corruption is real — control", %{store: store} do
    dir_uuid = corrupt_dir(store)

    assert raw_content(dir_uuid, store) == @spliced
    assert {:error, %Jason.DecodeError{}} = Jason.decode(raw_content(dir_uuid, store))

    # And the ordinary read path reports it as unreadable rather than
    # as an absence — the CX-r97r fail-loud property, at the meta layer.
    assert {:error, _} = World.get_meta_map(dir_uuid, Schemas.room_filename(), store)
  end

  test "Q2: a write aimed at a corrupt doc FAILS rather than silently overwriting", %{
    store: store
  } do
    dir_uuid = corrupt_dir(store)
    before = raw_content(dir_uuid, store)

    result = World.merge_meta(dir_uuid, Schemas.room_filename(), %{"description" => "new"}, store)

    # It must not succeed: succeeding would mean the corrupt body was
    # discarded and replaced, destroying the only evidence of what
    # happened. A refusal keeps the damaged bytes for forensics.
    refute result == :ok,
           "a write to a corrupt meta doc SUCCEEDED — the corrupt body would be silently " <>
             "replaced, erasing the evidence of a corruption incident"

    assert {:error, _} = result

    # And it changed nothing.
    assert raw_content(dir_uuid, store) == before,
           "the failed write still mutated the doc"
  end

  test "Q1: a corrupt doc does NOT silently repair itself through the normal write path", %{
    store: store
  } do
    dir_uuid = corrupt_dir(store)

    # Several successive writes, the scenario in which a "later write
    # overwrites the corrupt span" would show up.
    for i <- 1..3 do
      World.merge_meta(dir_uuid, Schemas.room_filename(), %{"n" => "#{i}"}, store)
    end

    content = raw_content(dir_uuid, store)

    assert {:error, %Jason.DecodeError{}} = Jason.decode(content),
           "the doc became READABLE again after later writes — a corrupt doc that silently " <>
             "repairs itself would explain CX-t3bt's reappearing entry AND would erase " <>
             "corruption evidence before anyone could look. Content: #{inspect(content)}"

    assert content == @spliced, "content changed despite every write failing"
  end

  test "recovery IS possible, but only by an explicit unconditional write", %{store: store} do
    dir_uuid = corrupt_dir(store)

    # merge_meta cannot recover it (it must read-then-merge). A direct
    # write_meta_doc can, because it replaces the body wholesale
    # without reading it as JSON. That asymmetry is the recovery
    # procedure: repair is possible, but never accidental.
    good = Schemas.encode_room(%Room{name: "Start", description: "Recovered."})
    assert :ok = Schemas.write_meta_doc(meta_node_id(dir_uuid, store), good, store)

    assert {:ok, %Room{description: "Recovered."}} = Schemas.load_room(dir_uuid, store)
    assert {:ok, _} = World.get_meta_map(dir_uuid, Schemas.room_filename(), store)

    # ...and once recovered, ordinary writes work again.
    assert :ok =
             World.merge_meta(
               dir_uuid,
               Schemas.room_filename(),
               %{"description" => "after"},
               store
             )

    assert {:ok, %Room{description: "after"}} = Schemas.load_room(dir_uuid, store)
  end
end
