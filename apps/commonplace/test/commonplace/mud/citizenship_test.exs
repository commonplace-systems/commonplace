defmodule Commonplace.MUD.CitizenshipTest do
  @moduledoc """
  CX-gjpi: `Commonplace.MUD.Citizenship.ensure/5` is the shared "become a
  citizen of this MUD world" seam a browser player's `MudLive` mount
  (and, via `Bot`, an MCP bot spawn) uses to get a presence-starter cert
  plus a node-signed `players/<name>/` home — BEFORE the player has
  authored a single commit of their own.

  Runs under `local_write_gate: :enforce` + `trust: %{accept_unsigned:
  false, ...}` (mirrors `PlayerSessionIdentityTest`'s strict+enforce
  scaffold) to prove every write `ensure/5` makes is genuinely
  node-signed and lands under the strict gate — not merely "would have
  been fine under the default permissive config".
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.Citizenship
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_citizenship_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"citizenship_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"citizenship_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"citizenship_tss_#{n}",
       pending_imports_name: :"citizenship_pi_#{n}"}
    )

    # `NodeIdentity` mints/reads its keypair from the app's configured
    # `:data_dir` — isolate that to this test's own tmp dir so the node
    # identity (and its auto-trust) is deterministic and doesn't collide
    # with any other suite's node key.
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    # `Commonplace.Trust` auto-trusts the node's own signing identity by
    # construction (see `NodeIdentity`'s moduledoc) — no
    # `trusted_identities` entry needs to be pinned for it. `strict` here
    # just means unsigned commits are rejected, and the local-write gate
    # actually enforces (not just dry-runs) capability checks.
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      case old_data_dir do
        nil -> Application.delete_env(:commonplace, :data_dir)
        v -> Application.put_env(:commonplace, :data_dir, v)
      end

      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    root_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())

    assert %Commonplace.Store.Commit{} =
             CommitStore.create_commit(store, root_uuid, update, nil, %{}, signing_context: node_ctx)

    {identity_uuid, pub} = fresh_identity()

    %{store: store, root: root_uuid, identity_uuid: identity_uuid, pub: pub}
  end

  defp fresh_identity do
    {pub, _priv} = Signing.generate_keypair()
    {UUID.uuid4(), pub}
  end

  test "issues the presence-starter cert and the home-zone cert as TWO SEPARATE grants (presence ⊥ ownership)",
       %{store: store, root: root, identity_uuid: identity_uuid, pub: pub} do
    assert {:ok, %{cert_cids: cids, home_room_uuid: home_uuid}} =
             Citizenship.ensure(identity_uuid, pub, "arwen", root, store)

    # Two distinct certs — never one merged over-broad grant.
    assert length(cids) == 2
    assert Enum.uniq(cids) == cids

    caps =
      Enum.map(cids, fn cid ->
        assert {:ok, cap} = CommitStoreClient.get_capability(store, cid)
        cap
      end)

    scopes = Enum.map(caps, & &1.claim.scope)
    # One is presence-only (citizenship), the other is {:subtree, home_dir}
    # over the player's OWN home SUBTREE (CX-4u03 A4 — supersedes the old
    # {:docs, [meta]}) — presence authority never grants zone-edit and the
    # zone cert never grants presence.
    assert {:presence, identity_uuid} in scopes
    assert {:subtree, home_uuid} in scopes

    assert {:ok, node_identity} = NodeIdentity.identity()

    for cap <- caps do
      assert cap.claim.verbs == [:write]
      assert {^identity_uuid, _pub} = cap.audience
      assert {^node_identity, _} = cap.issuer
    end
  end

  test "provisions players/<name>/ as an OWNED home ROOM (__room.json + inventory), node-signed", %{
    store: store,
    root: root,
    identity_uuid: identity_uuid,
    pub: pub
  } do
    assert {:ok, %{home_room_uuid: home_uuid, home_room_meta_uuid: home_meta}} =
             Citizenship.ensure(identity_uuid, pub, "arwen", root, store)

    {:ok, root_schema} = Commonplace.MUD.Schemas.load_dir_schema(root, store)
    assert {:ok, players_entry} = Schema.get_entry(root_schema, "players")

    {:ok, players_schema} = Commonplace.MUD.Schemas.load_dir_schema(players_entry.node_id, store)
    assert {:ok, player_entry} = Schema.get_entry(players_schema, "arwen")
    assert player_entry.node_id == home_uuid

    {:ok, player_schema} = Commonplace.MUD.Schemas.load_dir_schema(home_uuid, store)
    # The home dir is a ROOM: it carries a __room.json meta, and that's
    # exactly the doc the ownership zone cert covers.
    assert {:ok, room_entry} = Schema.get_entry(player_schema, Commonplace.MUD.Schemas.room_filename())
    assert room_entry.node_id == home_meta
    assert {:ok, _inv_entry} = Schema.get_entry(player_schema, "inventory")

    assert {:ok, room_doc} = DocBuilder.reconstruct_doc(store, home_meta)
    assert {:ok, %{"name" => "arwen's Home"}} = Jason.decode(ContentType.get_content(room_doc))

    # Every provisioning write landed NODE-SIGNED, under `:enforce`.
    assert {:ok, node_identity} = NodeIdentity.identity()
    node_signer_id = Signing.signer_id(node_identity, elem(node_signing_context(), 1))

    for uuid <- [players_entry.node_id, home_uuid, home_meta, root] do
      assert {:ok, commit} = CommitStore.latest_commit(store, uuid)
      assert commit.signer_id == node_signer_id
    end
  end

  test "idempotent: ensure/5 twice re-lands the same certs and does not duplicate the home",
       %{store: store, root: root, identity_uuid: identity_uuid, pub: pub} do
    assert {:ok, %{cert_cids: cids1}} = Citizenship.ensure(identity_uuid, pub, "arwen", root, store)

    {:ok, root_schema1} = Commonplace.MUD.Schemas.load_dir_schema(root, store)
    {:ok, players_entry1} = Schema.get_entry(root_schema1, "players")
    {:ok, players_head_1} = CommitStore.latest_commit(store, players_entry1.node_id)

    assert {:ok, %{cert_cids: cids2}} = Citizenship.ensure(identity_uuid, pub, "arwen", root, store)

    # Content-addressed certs re-land on the same cids (set-equal).
    assert Enum.sort(cids1) == Enum.sort(cids2)

    {:ok, root_schema2} = Commonplace.MUD.Schemas.load_dir_schema(root, store)
    {:ok, players_entry2} = Schema.get_entry(root_schema2, "players")
    assert players_entry2.node_id == players_entry1.node_id

    {:ok, players_head_2} = CommitStore.latest_commit(store, players_entry2.node_id)
    # No second `players` dir entry the second time — its schema head
    # does not move.
    assert players_head_2.id == players_head_1.id

    {:ok, players_schema} = Commonplace.MUD.Schemas.load_dir_schema(players_entry2.node_id, store)
    arwen_entries = Schema.list_entries(players_schema) |> Enum.filter(&(&1.name == "arwen"))
    assert length(arwen_entries) == 1
  end

  test "a second, different identity gets its OWN home + own certs without disturbing the first", %{
    store: store,
    root: root,
    identity_uuid: identity_uuid,
    pub: pub
  } do
    assert {:ok, _} = Citizenship.ensure(identity_uuid, pub, "arwen", root, store)

    {other_uuid, other_pub} = fresh_identity()
    assert {:ok, %{cert_cids: other_cids}} = Citizenship.ensure(other_uuid, other_pub, "beorn", root, store)

    other_scopes =
      Enum.map(other_cids, fn cid ->
        assert {:ok, cap} = CommitStoreClient.get_capability(store, cid)
        cap.claim.scope
      end)

    assert {:presence, other_uuid} in other_scopes

    {:ok, root_schema} = Commonplace.MUD.Schemas.load_dir_schema(root, store)
    {:ok, players_entry} = Schema.get_entry(root_schema, "players")
    {:ok, players_schema} = Commonplace.MUD.Schemas.load_dir_schema(players_entry.node_id, store)

    assert {:ok, _} = Schema.get_entry(players_schema, "arwen")
    assert {:ok, _} = Schema.get_entry(players_schema, "beorn")
  end

  defp node_signing_context do
    {:ok, %SigningContext{public_key: pub}} = NodeIdentity.signing_context()
    {:ok, pub}
  end
end
