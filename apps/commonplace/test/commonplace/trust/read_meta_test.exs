defmodule Commonplace.Trust.ReadMetaTest do
  @moduledoc """
  CX-ivqz (read-scoping P2) — `Commonplace.Trust.ReadMeta`: the canonical
  carried-fields resolver for by-uuid read surfaces. Covers the two carried
  SHAPES (text JSON room doc + XML view-doc) and the load-bearing
  default-public posture for every unparseable/absent/garbage input.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{Schemas, SessionView}
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.ReadMeta

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_read_meta_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"read_meta_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"read_meta_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"read_meta_tss_#{n}",
       pending_imports_name: :"read_meta_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store, dir: dir}
  end

  defp commit_text_doc(store, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "test")
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp commit_room_doc(store, room) do
    commit_text_doc(store, Schemas.encode_room(room))
  end

  # --- text JSON room doc ---

  test "room JSON doc: capability_gated + owner carried through", %{store: store} do
    owner = "owner-#{:rand.uniform(999_999)}"

    uuid =
      commit_room_doc(store, %Room{
        name: "Private Home",
        description: "cozy",
        owner: owner,
        visibility: :capability_gated
      })

    assert %{visibility: :capability_gated, owner: ^owner} = ReadMeta.resolve(uuid, store)
  end

  test "room JSON doc: explicit public → public", %{store: store} do
    uuid =
      commit_room_doc(store, %Room{name: "Plaza", description: "open", visibility: :public})

    assert %{visibility: :public, owner: nil} = ReadMeta.resolve(uuid, store)
  end

  test "room JSON doc: absent visibility/owner (pre-P2 room) → public/nil", %{store: store} do
    # encode_room omits owner/visibility when default, so this JSON has
    # neither key — a legacy room. Must resolve to the no-regression default.
    uuid = commit_room_doc(store, %Room{name: "Old Room", description: "legacy"})
    json = Schemas.encode_room(%Room{name: "Old Room", description: "legacy"})
    refute json =~ "visibility"
    refute json =~ "owner"

    assert %{visibility: :public, owner: nil} = ReadMeta.resolve(uuid, store)
  end

  # --- XML view-doc shape ---

  test "view-doc XML: reads capability_gated + owner from the <view> attributes", %{store: store} do
    {pub, priv} = Signing.generate_keypair()
    id = "vvvv0000-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"
    ctx = %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}

    view = SessionView.new(id, store, signing_context: ctx)

    # SessionView.new mints owner=id, visibility=capability_gated.
    assert %{visibility: :capability_gated, owner: ^id} = ReadMeta.resolve(view.uuid, store)
  end

  # --- default-public posture ---

  test "plain (non-JSON) text doc → public", %{store: store} do
    uuid = commit_text_doc(store, "just some prose, not json at all")
    assert %{visibility: :public, owner: nil} = ReadMeta.resolve(uuid, store)
  end

  test "JSON that decodes to a non-map (a list) → public", %{store: store} do
    uuid = commit_text_doc(store, ~s(["capability_gated", "not", "a", "map"]))
    assert %{visibility: :public, owner: nil} = ReadMeta.resolve(uuid, store)
  end

  test "JSON scalar (a bare string) → public", %{store: store} do
    uuid = commit_text_doc(store, ~s("capability_gated"))
    assert %{visibility: :public, owner: nil} = ReadMeta.resolve(uuid, store)
  end

  test "nonexistent uuid → public (existence not leaked, no over-exposure)", %{store: store} do
    assert %{visibility: :public, owner: nil} =
             ReadMeta.resolve("00000000-0000-0000-0000-000000000000", store)
  end

  test "malformed owner value (non-string in JSON map) coerces to nil, visibility public", %{
    store: store
  } do
    uuid = commit_text_doc(store, ~s({"owner": 42, "visibility": "nonsense"}))
    assert %{visibility: :public, owner: nil} = ReadMeta.resolve(uuid, store)
  end
end
