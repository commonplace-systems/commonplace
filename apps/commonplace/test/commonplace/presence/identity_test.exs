defmodule Commonplace.Presence.IdentityTest do
  @moduledoc """
  Tests for cold identity — permanent actor records in __identities/.
  """
  use ExUnit.Case

  alias Commonplace.Presence.Identity
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_identity_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Create a root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  describe "ensure_identities_dir" do
    test "creates __identities__ entry in root schema", %{store: store, root: root} do
      {:ok, dir_uuid} = Identity.ensure_identities_dir(root, store)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "__identities__")
      assert entry.type == :dir
      assert entry.node_id == dir_uuid
    end

    test "returns existing dir if already created", %{store: store, root: root} do
      {:ok, uuid1} = Identity.ensure_identities_dir(root, store)
      {:ok, uuid2} = Identity.ensure_identities_dir(root, store)
      assert uuid1 == uuid2
    end
  end

  describe "register" do
    test "creates a new cold identity", %{store: store, root: root} do
      {:ok, identity_uuid} = Identity.register("sync", :exe, root, store)

      identity = Identity.read(identity_uuid, store)
      assert identity["name"] == "sync"
      assert identity["type"] == "exe"
      assert is_binary(identity["first_seen"])
      assert is_binary(identity["last_seen"])
    end

    test "identity appears in __identities__ schema", %{store: store, root: root} do
      {:ok, _uuid} = Identity.register("sync", :exe, root, store)

      {:ok, id_dir_uuid} = Identity.ensure_identities_dir(root, store)
      id_doc = load_schema(id_dir_uuid, store)
      {:ok, entry} = Schema.get_entry(id_doc, "sync.exe")
      assert entry.type == :doc
    end

    test "returns existing identity on re-register", %{store: store, root: root} do
      {:ok, uuid1} = Identity.register("sync", :exe, root, store)
      Process.sleep(10)
      {:ok, uuid2} = Identity.register("sync", :exe, root, store)

      assert uuid1 == uuid2

      # last_seen should be updated
      identity = Identity.read(uuid2, store)
      assert identity["name"] == "sync"
    end

    test "updates last_seen on re-register", %{store: store, root: root} do
      {:ok, uuid} = Identity.register("sync", :exe, root, store)
      first = Identity.read(uuid, store)

      Process.sleep(10)
      {:ok, ^uuid} = Identity.register("sync", :exe, root, store)
      second = Identity.read(uuid, store)

      assert second["first_seen"] == first["first_seen"]
      assert second["last_seen"] != first["last_seen"]
    end
  end

  describe "lookup" do
    test "finds a registered identity", %{store: store, root: root} do
      {:ok, uuid} = Identity.register("agent", :bot, root, store)

      assert {:ok, ^uuid} = Identity.lookup("agent", :bot, root, store)
    end

    test "returns :error for unregistered identity", %{store: store, root: root} do
      assert :error = Identity.lookup("ghost", :exe, root, store)
    end
  end

  describe "list" do
    test "lists all cold identities", %{store: store, root: root} do
      Identity.register("alpha", :exe, root, store)
      Identity.register("beta", :bot, root, store)
      Identity.register("jes", :usr, root, store)

      identities = Identity.list(root, store)
      assert length(identities) == 3
      names = Enum.map(identities, & &1.name) |> Enum.sort()
      assert names == ["alpha.exe", "beta.bot", "jes.usr"]
    end

    test "returns empty list when no identities", %{store: store, root: root} do
      assert Identity.list(root, store) == []
    end
  end

  describe "in-memory Yjs merge with distinct client_ids (CX-6g6 codex P1 round 1)" do
    # SCOPE: these tests exercise ONLY the in-memory Yjs merge path —
    # Yelixer.Encoding.apply_update/2 on two concurrent updates from writers
    # with distinct client_ids. They do NOT exercise the CommitStore write
    # path (`latest_commit -> mutate -> create_chained_commit`), where two
    # nodes racing on the same identity UUID still produce sibling commits
    # and only one becomes `:latest`. Full multi-writer correctness through
    # the commit-chain layer (sibling-commit merge / :latest reconciliation)
    # is tracked as a separate P1 follow-up bead; see the docstring on
    # `stable_client_id/1` in identity.ex for the detailed scope note.
    #
    # What this describe block verifies is the *prerequisite* for that
    # follow-up: if identity writes from different nodes ever reach the
    # same in-memory Yelixer.Doc — whether via a future sibling-commit
    # merge, a catch-up sync, or a snapshot rebuild — their updates carry
    # distinct (client_id, clock) pairs and both survive. A previous
    # implementation hashed the identity UUID alone, giving every node the
    # same client_id and silently collapsing concurrent writes even at
    # this in-memory layer.
    test "in-memory apply_update with distinct client_ids merges both writers",
         %{store: store, root: root} do
      alias Commonplace.Document.ContentType
      alias Commonplace.Store.CommitStoreClient

      # Register a shared identity doc and fetch its base state.
      {:ok, identity_uuid} = Identity.register("shared", :exe, root, store)
      {:ok, base_commit} = CommitStoreClient.latest_commit(store, identity_uuid)

      # Simulate writer A (e.g. node alpha) — distinct explicit client_id.
      doc_a = Yelixer.Doc.new(client_id: 100_001)
      {:ok, doc_a} = Yelixer.Encoding.apply_update(doc_a, base_commit.update)
      doc_a = ContentType.set_key(doc_a, "written_by_a", "alpha_value")
      update_a = Yelixer.Encoding.encode_update(doc_a)

      # Simulate writer B (e.g. node beta) — different explicit client_id,
      # same base state, concurrent write to a different key.
      doc_b = Yelixer.Doc.new(client_id: 100_002)
      {:ok, doc_b} = Yelixer.Encoding.apply_update(doc_b, base_commit.update)
      doc_b = ContentType.set_key(doc_b, "written_by_b", "beta_value")
      update_b = Yelixer.Encoding.encode_update(doc_b)

      # Merge both updates into a fresh observer doc. With the fix, both
      # concurrent writes retain distinct (client_id, clock) pairs and both
      # survive. With the old phash2(uuid)-only derivation, writers A and B
      # would share a client_id, reuse the same clock, and one set would be
      # silently dropped here.
      observer = Yelixer.Doc.new()
      {:ok, observer} = Yelixer.Encoding.apply_update(observer, update_a)
      {:ok, observer} = Yelixer.Encoding.apply_update(observer, update_b)

      content = ContentType.get_content(observer)
      assert content["written_by_a"] == "alpha_value",
             "writer A's concurrent change was dropped — client_id collision regression"
      assert content["written_by_b"] == "beta_value",
             "writer B's concurrent change was dropped — client_id collision regression"

      # Ordering of apply should not matter: reverse the merge and verify.
      observer2 = Yelixer.Doc.new()
      {:ok, observer2} = Yelixer.Encoding.apply_update(observer2, update_b)
      {:ok, observer2} = Yelixer.Encoding.apply_update(observer2, update_a)

      content2 = ContentType.get_content(observer2)
      assert content2["written_by_a"] == "alpha_value"
      assert content2["written_by_b"] == "beta_value"
    end

    # The previous implementation derived the write client_id from
    # `:erlang.phash2(uuid, ...)` alone. That meant every BEAM node writing
    # to the same identity doc derived the SAME client_id — exactly the
    # collision scenario exercised above — so concurrent writes from
    # different nodes would silently drop one side.
    #
    # The fix derives client_id from `{node(), uuid}`, so different nodes
    # get different client_ids. We can't easily change node() in a test,
    # but we CAN observe the client_id an Identity write actually persists
    # and confirm it matches the node-scoped derivation.
    test "Identity writes derive client_id from {node(), uuid}, not uuid alone",
         %{store: store, root: root} do
      alias Commonplace.Store.CommitStoreClient

      {:ok, identity_uuid} = Identity.register("nodescoped", :exe, root, store)

      {:ok, commit} = CommitStoreClient.latest_commit(store, identity_uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      sv = Yelixer.BlockStore.state_vector(doc.store)

      post_fix_client_id = :erlang.phash2({node(), identity_uuid}, 0xFFFF_FFFF)

      assert Map.has_key?(sv.clocks, post_fix_client_id),
             "state vector missing node-scoped client_id #{post_fix_client_id}: #{inspect(Map.keys(sv.clocks))}"
    end
  end

  describe "GenServer integration" do
    test "Presence.Server registers cold identity on start", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "coldtest",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      # Cold identity should exist
      assert {:ok, _uuid} = Identity.lookup("coldtest", :exe, root, store)

      GenServer.stop(pid)
    end

    test "cold identity persists after clean shutdown", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "survivor",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      GenServer.stop(pid)
      Process.sleep(50)

      # Hot presence is gone
      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "survivor.exe")

      # Cold identity persists
      assert {:ok, _uuid} = Identity.lookup("survivor", :exe, root, store)
    end

    test "cold identity last_seen updated on shutdown", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "timestamped",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      identity_uuid = Commonplace.Presence.Server.identity_uuid(pid)
      before_stop = Identity.read(identity_uuid, store)

      Process.sleep(10)
      GenServer.stop(pid)
      Process.sleep(50)

      after_stop = Identity.read(identity_uuid, store)
      assert after_stop["last_seen"] != before_stop["last_seen"]
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
