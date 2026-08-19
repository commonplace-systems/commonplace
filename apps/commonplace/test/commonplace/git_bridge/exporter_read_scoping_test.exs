defmodule Commonplace.GitBridge.ExporterReadScopingTest do
  @moduledoc """
  CX-ivqz (read-scoping P2, Seam 5): GitBridge must skip a
  `capability_gated` zone's WHOLE SUBTREE (a private home must never land
  on the public mirror), while every default-public entry exports EXACTLY
  as before (the top deploy risk = a public-content regression).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Document.ContentType
  alias Commonplace.GitBridge.Exporter
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_rs_store_#{:rand.uniform(1_000_000_000)}")
    repo_dir = Path.join(System.tmp_dir!(), "cp_gb_rs_repo_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(repo_dir)

    store_name = :"gb_rs_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(repo_dir)
    end)

    %{store: store_name, repo_dir: repo_dir}
  end

  defp create_text(store, uuid, name, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_room_meta(store, uuid, %Room{} = room) do
    create_text(store, uuid, Schemas.room_filename(), Schemas.encode_room(room))
  end

  defp create_schema(store, uuid, schema_doc) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  # Flip an existing room-meta doc's visibility with a NEW chained commit
  # on the SAME uuid (delta-encoded, mirroring SessionView's append pattern)
  # so ReadMeta's full-chain reconstruct sees the updated JSON.
  defp flip_room_meta(store, meta_uuid, %Room{} = new_room) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, meta_uuid)
    sv_before = Yelixer.BlockStore.state_vector(doc.store)
    old = ContentType.get_content(doc) || ""
    doc = ContentType.delete_text(doc, 0, String.length(old))
    doc = ContentType.insert_text(doc, 0, Schemas.encode_room(new_room))
    diff = Yelixer.Encoding.encode_diff(doc, sv_before)
    CommitStore.create_chained_commit(store, meta_uuid, diff)
  end

  test "no-regression: a PUBLIC tree (with a public __room.json dir) exports EXACTLY as expected",
       %{store: store, repo_dir: dir} do
    create_text(store, "u-top", "top.txt", "top level")

    create_text(
      store,
      "u-plaza-meta",
      Schemas.room_filename(),
      Schemas.encode_room(%Room{name: "Plaza", description: "open", visibility: :public})
    )

    create_text(store, "u-sign", "sign.txt", "welcome")
    create_text(store, "u-note", "note.txt", "annex note")

    annex = Schema.new_schema() |> Schema.add_file("note.txt", "u-note")
    create_schema(store, "u-annex", annex)

    plaza =
      Schema.new_schema()
      |> Schema.add_file(Schemas.room_filename(), "u-plaza-meta")
      |> Schema.add_file("sign.txt", "u-sign")
      |> Schema.add_directory("annex", "u-annex")

    create_schema(store, "u-plaza", plaza)

    root =
      Schema.new_schema()
      |> Schema.add_file("top.txt", "u-top")
      |> Schema.add_directory("plaza", "u-plaza")

    create_schema(store, "u-root", root)

    {:ok, result} = Exporter.export("u-root", dir, store)

    # __room.json is filtered by the "__" rule (as always) — never in the
    # manifest; the public dir's OTHER contents export exactly as before.
    assert Enum.sort(Map.keys(result.manifest)) ==
             ["plaza/annex/note.txt", "plaza/sign.txt", "top.txt"]

    assert File.read!(Path.join(dir, "top.txt")) == "top level"
    assert File.read!(Path.join(dir, "plaza/sign.txt")) == "welcome"
    assert File.read!(Path.join(dir, "plaza/annex/note.txt")) == "annex note"
  end

  test "a capability_gated zone's WHOLE SUBTREE is skipped (no manifest, no disk)", %{
    store: store,
    repo_dir: dir
  } do
    # Public sibling stays exported.
    create_text(store, "u-lobby", "lobby.txt", "public lobby")

    create_room_meta(store, "u-secret-meta", %Room{
      name: "Private Home",
      description: "cozy",
      owner: "owner-x",
      visibility: :capability_gated
    })

    create_text(store, "u-diary", "diary.txt", "my secrets")
    create_text(store, "u-gold", "gold.txt", "treasure")

    vault = Schema.new_schema() |> Schema.add_file("gold.txt", "u-gold")
    create_schema(store, "u-vault", vault)

    secret =
      Schema.new_schema()
      |> Schema.add_file(Schemas.room_filename(), "u-secret-meta")
      |> Schema.add_file("diary.txt", "u-diary")
      |> Schema.add_directory("vault", "u-vault")

    create_schema(store, "u-secret", secret)

    root =
      Schema.new_schema()
      |> Schema.add_file("lobby.txt", "u-lobby")
      |> Schema.add_directory("secret", "u-secret")

    create_schema(store, "u-root", root)

    {:ok, result} = Exporter.export("u-root", dir, store)

    # Public sibling untouched.
    assert Map.has_key?(result.manifest, "lobby.txt")
    assert File.exists?(Path.join(dir, "lobby.txt"))

    # NOTHING under the gated zone — not the child doc, not the child subdir,
    # and the zone dir was never even created (no mkdir).
    refute Map.has_key?(result.manifest, "secret/diary.txt")
    refute Map.has_key?(result.manifest, "secret/vault/gold.txt")
    refute Enum.any?(Map.keys(result.manifest), &String.starts_with?(&1, "secret/"))
    refute File.exists?(Path.join(dir, "secret"))
    # The gated zone's schema uuid is NOT contributed either.
    refute MapSet.member?(result.schema_uuids, "u-secret")
    refute MapSet.member?(result.schema_uuids, "u-vault")
  end

  test "flipping a gated room PUBLIC makes the next export include the whole subtree", %{
    store: store,
    repo_dir: dir
  } do
    create_room_meta(store, "u-home-meta", %Room{
      name: "Home",
      description: "cozy",
      owner: "owner-y",
      visibility: :capability_gated
    })

    create_text(store, "u-item", "item.txt", "a lamp")

    home =
      Schema.new_schema()
      |> Schema.add_file(Schemas.room_filename(), "u-home-meta")
      |> Schema.add_file("item.txt", "u-item")

    create_schema(store, "u-home", home)
    root = Schema.new_schema() |> Schema.add_directory("home", "u-home")
    create_schema(store, "u-root", root)

    {:ok, gated_result} = Exporter.export("u-root", dir, store)
    refute Map.has_key?(gated_result.manifest, "home/item.txt")
    refute File.exists?(Path.join(dir, "home"))

    # Flip the room meta to public with a new commit on the SAME uuid.
    flip_room_meta(store, "u-home-meta", %Room{
      name: "Home",
      description: "cozy",
      owner: "owner-y",
      visibility: :public
    })

    {:ok, public_result} = Exporter.export("u-root", dir, store, gated_result.manifest)
    assert Map.has_key?(public_result.manifest, "home/item.txt")
    assert File.read!(Path.join(dir, "home/item.txt")) == "a lamp"
  end

  test "flipping a public room back to gated PRUNES its previously-exported files", %{
    store: store,
    repo_dir: dir
  } do
    create_room_meta(store, "u-home2-meta", %Room{
      name: "Home",
      description: "cozy",
      owner: "owner-z",
      visibility: :public
    })

    create_text(store, "u-item2", "item.txt", "a chair")

    home =
      Schema.new_schema()
      |> Schema.add_file(Schemas.room_filename(), "u-home2-meta")
      |> Schema.add_file("item.txt", "u-item2")

    create_schema(store, "u-home2", home)
    root = Schema.new_schema() |> Schema.add_directory("home2", "u-home2")
    create_schema(store, "u-root", root)

    # First export: public → files present.
    {:ok, public_result} = Exporter.export("u-root", dir, store)
    assert Map.has_key?(public_result.manifest, "home2/item.txt")
    assert File.exists?(Path.join(dir, "home2/item.txt"))

    # Flip to gated, then re-export with the public manifest as previous:
    # the zone is skipped this cycle, and prune/3's manifest-diff removes
    # the now-orphaned files from repo_dir (the intended retroactive
    # removal of a newly-private zone).
    flip_room_meta(store, "u-home2-meta", %Room{
      name: "Home",
      description: "cozy",
      owner: "owner-z",
      visibility: :capability_gated
    })

    {:ok, gated_result} = Exporter.export("u-root", dir, store, public_result.manifest)

    refute Map.has_key?(gated_result.manifest, "home2/item.txt")
    refute File.exists?(Path.join(dir, "home2/item.txt"))
    refute File.exists?(Path.join(dir, "home2"))
  end
end
